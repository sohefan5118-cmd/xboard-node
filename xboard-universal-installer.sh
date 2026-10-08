#!/usr/bin/env bash
# XBoard 跨节点万能安装器
# - controller: 在 A 上通过 SSH 部署 A/B/C，D 可选
# - node: 在单个节点上部署/修复 xboard-node
# - auto: 有 A_HOST/B_HOST/C_HOST 时作为 controller，否则作为 node
set -Eeuo pipefail
IFS=$'\n\t'

APP_ROOT="/etc/xboard-node"
STATE_DIR="${APP_ROOT}/universal"
ENV_FILE="${XBOARD_ENV_FILE:-$STATE_DIR/install.env}"
SOURCE_INSTALLER="${XBOARD_INSTALLER:-}"
REMOTE_INSTALLER="/tmp/xboard-universal-installer.sh"
MODE="auto"
CHECK_ONLY=0
DRY_RUN=0
ROLE=""

log(){ printf '\033[1;32m[xboard]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[xboard]\033[0m %s\n' "$*" >&2; }
die(){ printf '\033[1;31m[xboard ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }
run(){ if ((DRY_RUN)); then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi; }

usage(){ cat <<'EOF'
XBoard 跨节点万能安装器

本机部署/修复：
  sudo XBOARD_ROLE=A bash xboard-universal-installer.sh --node

以后新增任意节点（D/E/…）：
  sudo XBOARD_ROLE=node bash xboard-universal-installer.sh --node --env /root/xboard-node.env

从 A 控制三台节点（D 可选）：
  sudo bash xboard-universal-installer.sh --controller --env /root/xboard.env

选项：
  --controller       从当前机器通过 SSH 部署 A/B/C，D 可选
  --node             只部署当前机器
  --check            只检查，不写配置、不重启服务
  --dry-run          只打印动作
  --env FILE         安装参数文件
  --help             显示帮助

参数文件必须 chmod 600；不把 Token/Redis 密码写入命令行或脚本。
EOF
}

while (($#)); do
  case "$1" in
    --controller) MODE=controller; shift;;
    --node) MODE=node; shift;;
    --check) CHECK_ONLY=1; shift;;
    --dry-run) DRY_RUN=1; CHECK_ONLY=1; shift;;
    --env) (($# >= 2)) || die "--env 需要文件"; ENV_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "未知参数: $1";;
  esac
done

[[ $EUID -eq 0 ]] || die '请使用 root 执行'
[[ -r "$ENV_FILE" ]] || die "找不到参数文件: $ENV_FILE"
[[ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo 999)" =~ ^(600|640|400|440)$ ]] || die "$ENV_FILE 权限必须为 600/640/400/440"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${PANEL_URL:?参数文件缺少 PANEL_URL}"
: "${REDIS_ADDR:?参数文件缺少 REDIS_ADDR}"
: "${REDIS_PASSWORD:?参数文件缺少 REDIS_PASSWORD}"
: "${CLAIM_TTL:=300}"
: "${CLAIM_PREFIX:=xboard:device-claim}"
: "${KERNEL_TYPE:=singbox}"
# v1.13-ipv4 predates merge-safe multi-instance credentials. Keep the
# installer and xbctl from the same merge-safe dev release together.
: "${RELEASE_VERSION:=dev}"
: "${HEALTH_PORT:=65530}"
: "${SSH_USER:=root}"
: "${A_HOST:=}"
: "${B_HOST:=}"
: "${C_HOST:=}"
: "${D_HOST:=}"
: "${A_SSH_PORT:=22}"
: "${B_SSH_PORT:=22}"
: "${C_SSH_PORT:=22}"
: "${D_SSH_PORT:=22}"
: "${A_MODE:=machine}"
: "${B_MODE:=machine}"
: "${C_MODE:=machine}"
: "${D_MODE:=machine}"
: "${A_ID:=}"
: "${B_ID:=}"
: "${C_ID:=}"
: "${D_ID:=}"
: "${A_NODE_TYPE:=}"
: "${B_NODE_TYPE:=}"
: "${C_NODE_TYPE:=}"
: "${D_NODE_TYPE:=}"
: "${NODE_MODE:=machine}"
: "${NODE_ID:=}"
: "${NODE_TOKEN:=}"
: "${NODE_NODE_TYPE:=}"

[[ -n "$REDIS_PASSWORD" && "$REDIS_PASSWORD" != "***" ]] || die 'REDIS_PASSWORD 不能为空且不能使用脱敏占位符'

[[ $KERNEL_TYPE == singbox ]] || die '跨节点 device claim 强制要求 KERNEL_TYPE=singbox'
[[ $CLAIM_TTL =~ ^[0-9]+$ && $CLAIM_TTL -ge 90 ]] || die 'CLAIM_TTL 必须是不小于 90 的整数'
[[ $HEALTH_PORT =~ ^[0-9]+$ ]] || die 'HEALTH_PORT 必须是数字'
[[ $REDIS_ADDR =~ ^[^:]+:[0-9]+$ ]] || die 'REDIS_ADDR 必须为 host:port'
[[ $PANEL_URL =~ ^https?:// ]] || die 'PANEL_URL 必须以 http:// 或 https:// 开头'
redis_ping(){
  need redis-cli
  local host="${REDIS_ADDR%:*}" port="${REDIS_ADDR##*:}" out
  out=$(redis-cli --no-auth-warning -h "$host" -p "$port" -a "$REDIS_PASSWORD" --raw PING 2>/dev/null || true)
  [[ $out == PONG ]] || die "共享 Redis 不可用或密码错误: $REDIS_ADDR"
  log "共享 Redis 连通: $REDIS_ADDR"
}

find_installer(){
  if [[ -n "$SOURCE_INSTALLER" ]]; then [[ -r "$SOURCE_INSTALLER" ]] || die "XBOARD_INSTALLER 不存在"; echo "$SOURCE_INSTALLER"; return; fi
  local here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -r "$here/xboard-node-source/install.sh" ]]; then echo "$here/xboard-node-source/install.sh"; return; fi
  local tmp; tmp=$(mktemp)
  curl --fail --proto '=https' --tlsv1.2 -fsSL "${INSTALLER_URL:-https://raw.githubusercontent.com/sohefan5118-cmd/xboard-node/dev/install.sh}" -o "$tmp"
  chmod 700 "$tmp"; echo "$tmp"
}

atomic_claim_env(){
  local cred="$APP_ROOT/credentials.env" tmp
  [[ -f "$cred" ]] || die "安装器未生成 $cred"
  tmp=$(mktemp "$APP_ROOT/.credentials.XXXXXX")
  chmod 600 "$tmp"
  awk -F= '!/^(DEVICE_CLAIM_ENABLED|DEVICE_CLAIM_TYPE|DEVICE_CLAIM_ADDR|DEVICE_CLAIM_PASSWORD|DEVICE_CLAIM_DB|DEVICE_CLAIM_PREFIX|DEVICE_CLAIM_TTL)=/' "$cred" >"$tmp"
  {
    printf 'DEVICE_CLAIM_ENABLED=true\n'
    printf 'DEVICE_CLAIM_TYPE=redis\n'
    printf 'DEVICE_CLAIM_ADDR=%s\n' "$REDIS_ADDR"
    printf 'DEVICE_CLAIM_PASSWORD=%s\n' "$REDIS_PASSWORD"
    printf 'DEVICE_CLAIM_DB=0\n'
    printf 'DEVICE_CLAIM_PREFIX=%s\n' "$CLAIM_PREFIX"
    printf 'DEVICE_CLAIM_TTL=%s\n' "$CLAIM_TTL"
  } >>"$tmp"
  # Replace in one rename so systemd/the node never reads a partial env file.
  mv -f "$tmp" "$cred"
  chmod 600 "$cred"
}

local_role(){
  [[ -n "$ROLE" ]] && { echo "$ROLE"; return; }
  ROLE="${XBOARD_ROLE:-}"
  if [[ -z "$ROLE" ]]; then
    if [[ -n "$A_HOST" && -n "$B_HOST" && -n "$C_HOST" ]]; then ROLE=controller; else ROLE=node; fi
  fi
  echo "$ROLE"
}

node_id_for(){
  local role="$1"; case "$role" in A) echo "$A_ID";; B) echo "$B_ID";; C) echo "$C_ID";; D) echo "$D_ID";; node) echo "$NODE_ID";; *) echo "";; esac
}
node_mode_for(){
  local role="$1"; case "$role" in A) echo "$A_MODE";; B) echo "$B_MODE";; C) echo "$C_MODE";; D) echo "$D_MODE";; node) echo "$NODE_MODE";; *) echo "";; esac
}
node_type_for(){
  local role="$1"; case "$role" in A) echo "$A_NODE_TYPE";; B) echo "$B_NODE_TYPE";; C) echo "$C_NODE_TYPE";; D) echo "$D_NODE_TYPE";; node) echo "$NODE_NODE_TYPE";; *) echo "";; esac
}

install_node(){
  local role="${1:-${XBOARD_ROLE:-node}}" mode ident token installer node_type
  [[ $role =~ ^(A|B|C|D|node)$ ]] || die "无效角色: $role"
  mode=$(node_mode_for "$role"); ident=$(node_id_for "$role"); node_type=$(node_type_for "$role")
  [[ $mode == node || $mode == machine ]] || die "$role: MODE 必须为 node 或 machine"
  [[ $ident =~ ^[0-9]+$ ]] || die "$role: ID 必须为正整数"
  case "$role" in A) token="${A_TOKEN:-}";; B) token="${B_TOKEN:-}";; C) token="${C_TOKEN:-}";; D) token="${D_TOKEN:-}";; node) token="$NODE_TOKEN";; esac
  [[ -n "$token" ]] || die "$role: 缺少对应 Token"
  redis_ping
  installer=$(find_installer)
  if ((CHECK_ONLY)); then
    log "$role: 预检查通过（不安装、不改配置）"; return
  fi
  # Pass Claim settings through the protected environment so the official
  # installer renders them into the staged credentials before first start.
  # The values never enter argv or normal logs.
  export DEVICE_CLAIM_ENABLED=true
  export DEVICE_CLAIM_TYPE=redis
  export DEVICE_CLAIM_ADDR="$REDIS_ADDR"
  export DEVICE_CLAIM_PASSWORD="$REDIS_PASSWORD"
  export DEVICE_CLAIM_DB=0
  export DEVICE_CLAIM_PREFIX="$CLAIM_PREFIX"
  export DEVICE_CLAIM_TTL="$CLAIM_TTL"
  local args=(--mode "$mode" --panel "$PANEL_URL" --token "$token" --kernel singbox --version "$RELEASE_VERSION" --health-port "$HEALTH_PORT" --yes)
  if [[ $mode == machine ]]; then args+=(--machine-id "$ident"); else args+=(--node-id "$ident"); [[ -n "$node_type" ]] && args+=(--node-type "$node_type"); fi
  log "$role: 安装/升级 xboard-node（sing-box）"
  bash "$installer" "${args[@]}"
  # The official installer already staged Claim credentials atomically. Keep
  # this final check as an acceptance gate; do not rewrite or expose secrets
  # after the service has started.
  chmod 600 "$APP_ROOT/credentials.env"
  systemctl daemon-reload
  systemctl restart xboard-node.service
  sleep 2
  systemctl is-active --quiet xboard-node.service || { journalctl -u xboard-node.service -n 60 --no-pager; die "$role: 服务未 active"; }
  grep -q '^DEVICE_CLAIM_ENABLED=true$' "$APP_ROOT/credentials.env" || die "$role: Claim 未写入"
  grep -q '^DEVICE_CLAIM_TYPE=redis$' "$APP_ROOT/credentials.env" || die "$role: Claim 类型错误"
  log "$role: 完成；服务 active，Claim=Redis，内核=sing-box"
}

remote_node(){
  local role="$1" host port id token mode node_type tmp remote_env
  case "$role" in A) host="$A_HOST"; port="$A_SSH_PORT";; B) host="$B_HOST"; port="$B_SSH_PORT";; C) host="$C_HOST"; port="$C_SSH_PORT";; D) host="$D_HOST"; port="$D_SSH_PORT";; esac
  [[ -n "$host" ]] || die "${role}_HOST 未配置"
  tmp=$(mktemp); chmod 600 "$tmp"
  remote_env="$tmp"
  # 只为该节点生成临时参数，完成后删除；密码通过 stdin/scp 传输，不拼接 SSH 命令。
  local role_token
  case "$role" in
    A) role_token="${A_TOKEN:-}";;
    B) role_token="${B_TOKEN:-}";;
    C) role_token="${C_TOKEN:-}";;
    D) role_token="${D_TOKEN:-}";;
    *) role_token="";;
  esac
  {
    printf 'PANEL_URL=%q\nREDIS_ADDR=%q\nREDIS_PASSWORD=%q\nDEVICE_CLAIM_ENABLED=true\nDEVICE_CLAIM_TYPE=redis\nDEVICE_CLAIM_ADDR=%q\nDEVICE_CLAIM_PASSWORD=%q\nDEVICE_CLAIM_DB=0\nDEVICE_CLAIM_PREFIX=%q\nDEVICE_CLAIM_TTL=%q\nKERNEL_TYPE=singbox\nRELEASE_VERSION=%q\nHEALTH_PORT=%q\nSSH_USER=%q\n' \
      "$PANEL_URL" "$REDIS_ADDR" "$REDIS_PASSWORD" "$REDIS_ADDR" "$REDIS_PASSWORD" \
      "$CLAIM_PREFIX" "$CLAIM_TTL" "$RELEASE_VERSION" "$HEALTH_PORT" "$SSH_USER"
    printf 'XBOARD_ROLE=%q\n%s_TOKEN=%q\n%s_MODE=%q\n%s_ID=%q\n%s_NODE_TYPE=%q\n' "$role" "$role" "$role_token" "$role" "$(node_mode_for "$role")" "$role" "$(node_id_for "$role")" "$role" "$(node_type_for "$role")"
  } >"$remote_env"
  need ssh; need scp
  log "$role: 连接 $host:$port"
  scp -q -P "$port" "$BASH_SOURCE" "$SSH_USER@$host:$REMOTE_INSTALLER"
  scp -q -P "$port" "$remote_env" "$SSH_USER@$host:/tmp/xboard-install.env"
  if ((CHECK_ONLY || DRY_RUN)); then
    ssh -p "$port" "$SSH_USER@$host" "chmod 700 '$REMOTE_INSTALLER'; XBOARD_ROLE=$role bash '$REMOTE_INSTALLER' --node --check --env /tmp/xboard-install.env"
  else
    ssh -p "$port" "$SSH_USER@$host" "chmod 700 '$REMOTE_INSTALLER'; XBOARD_ROLE=$role bash '$REMOTE_INSTALLER' --node --env /tmp/xboard-install.env; rm -f '$REMOTE_INSTALLER' /tmp/xboard-install.env"
  fi
  rm -f "$remote_env"
}

controller(){
  [[ -n "$A_HOST" && -n "$B_HOST" && -n "$C_HOST" ]] || die 'controller 模式必须配置 A_HOST/B_HOST/C_HOST'
  need ssh; need scp
  local roles=(A B C)
  [[ -n "$D_HOST" ]] && roles+=(D)
  for r in "${roles[@]}"; do remote_node "$r"; done
  log "${roles[*]} 部署完成；下一步需要从真实客户端执行跨节点准入验收。"
}

case "$MODE" in
  controller) controller;;
  node) install_node "${XBOARD_ROLE:-node}";;
  auto) [[ $(local_role) == controller ]] && controller || install_node "${XBOARD_ROLE:-node}";;
  *) die "内部模式错误";;
esac
