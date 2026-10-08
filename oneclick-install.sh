#!/usr/bin/env bash
# XBoard node one-click installer: install node/machine + shared Redis device claim.
# Interactive prompts are retained for manual use. Set MODE/PANEL/TOKEN/IDENT/
# REDIS_ADDR/REDIS_PASS for a completely non-interactive one-command install.
set -Eeuo pipefail
umask 077

[[ $EUID -eq 0 ]] || { echo '请用 root 执行'; exit 1; }
command -v systemctl >/dev/null || { echo '需要 systemd 系统'; exit 1; }

say(){ printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

prompt(){
  local var="$1" text="$2" secret="${3:-0}" value
  if [[ -n ${!var:-} ]]; then return; fi
  if [[ ${NONINTERACTIVE:-0} == 1 ]]; then die "非交互模式缺少参数: $var"; fi
  if [[ $secret == 1 ]]; then read -rsp "$text" value; echo; else read -rp "$text" value; fi
  printf -v "$var" '%s' "$value"
}

prompt MODE '模式 node/machine [machine]: '
MODE=${MODE:-machine}
[[ $MODE == node || $MODE == machine ]] || die '模式只能是 node 或 machine'
prompt PANEL '面板地址 https://...: '
[[ $PANEL =~ ^https?:// ]] || die '面板地址必须以 http:// 或 https:// 开头'
prompt TOKEN '节点/机器 Token: ' 1
[[ -n $TOKEN ]] || die 'Token 不能为空'
[[ $TOKEN != '***' ]] || die 'Token 不能使用脱敏占位符 ***'
if [[ $MODE == machine ]]; then
  prompt IDENT 'Machine ID: '
  ARG_ID=(--machine-id "$IDENT")
else
  prompt IDENT 'Node ID: '
  ARG_ID=(--node-id "$IDENT")
fi
[[ $IDENT =~ ^[0-9]+$ ]] || die 'ID 必须是数字'

prompt REDIS_ADDR '共享 Redis 地址 host:port [A内网IP:6379]: '
REDIS_ADDR=${REDIS_ADDR:-A内网IP:6379}
[[ $REDIS_ADDR =~ ^[^:]+:[0-9]+$ ]] || die 'Redis 地址格式应为 host:port'
prompt REDIS_PASS '共享 Redis 密码: ' 1
[[ -n $REDIS_PASS ]] || die 'Redis 密码不能为空'
prompt CLAIM_TTL 'Claim TTL 秒 [300]: '
CLAIM_TTL=${CLAIM_TTL:-300}
[[ $CLAIM_TTL =~ ^[0-9]+$ && $CLAIM_TTL -ge 90 ]] || die 'TTL 必须是不小于 90 的数字'
: "${CLAIM_PREFIX:=xboard:device-claim}"
# Preserve existing node/machine instances by default. Set REPLACE_EXISTING=1
# only when intentionally rebuilding this host as a single target.
: "${REPLACE_EXISTING:=0}"
: "${INSTALLER_URL:=https://raw.githubusercontent.com/sohefan5118-cmd/xboard-node/dev/install.sh}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates redis-tools python3-minimal >/dev/null

say '测试共享 Redis 连通性...'
PONG=$(redis-cli --no-auth-warning -h "${REDIS_ADDR%:*}" -p "${REDIS_ADDR##*:}" -a "$REDIS_PASS" PING 2>/dev/null || true)
[[ $PONG == PONG ]] || die "Redis 测试失败：$PONG（检查 A 的监听、防火墙、地址和密码）"

# Pass Claim settings into the official installer before it renders config and
# starts systemd. The official installer writes them into the staged
# credentials.env atomically, so there is no window where the service runs
# without Claim settings and no second restart that can interrupt traffic.
export DEVICE_CLAIM_ENABLED=true
export DEVICE_CLAIM_TYPE=redis
export DEVICE_CLAIM_ADDR="$REDIS_ADDR"
export DEVICE_CLAIM_PASSWORD="$REDIS_PASS"
export DEVICE_CLAIM_DB=0
export DEVICE_CLAIM_PREFIX="$CLAIM_PREFIX"
export DEVICE_CLAIM_TTL="$CLAIM_TTL"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
say '下载并执行官方安装器...'
curl --fail --proto '=https' --tlsv1.2 -fsSL \
  "$INSTALLER_URL" \
  -o "$TMP/install.sh"
chmod 700 "$TMP/install.sh"
# v1.13-ipv4 predates multi-instance preservation; dev contains the
# merge-safe xboard-node and xbctl artifacts.
RELEASE_VERSION=${RELEASE_VERSION:-dev}
REPLACE_ARGS=()
if [[ $REPLACE_EXISTING == 1 ]]; then
  REPLACE_ARGS+=(--replace-existing)
else
  REPLACE_ARGS+=(--keep-existing)
fi
bash "$TMP/install.sh" --mode "$MODE" --panel "$PANEL" --token "$TOKEN" "${ARG_ID[@]}" --version "$RELEASE_VERSION" --yes "${REPLACE_ARGS[@]}"

CRED=/etc/xboard-node/credentials.env
[[ -f $CRED ]] || die "安装完成但找不到 $CRED"
chmod 600 "$CRED"
grep -q '^DEVICE_CLAIM_ENABLED=true$' "$CRED" || die '安装完成但 Claim 配置未写入'
grep -q '^DEVICE_CLAIM_PASSWORD=' "$CRED" || die '安装完成但 Claim 密码未写入'
claim_password=$(sed -n 's/^DEVICE_CLAIM_PASSWORD=//p' "$CRED")
[[ -n $claim_password && $claim_password != '***' ]] || die '安装完成但 Claim 密码是空值或脱敏占位符'
systemctl is-active --quiet xboard-node.service || die 'xboard-node 安装后未运行'

say '安装成功'
echo "面板: $PANEL"
echo "模式: $MODE / ID: $IDENT"
echo "Redis: $REDIS_ADDR"
echo '服务: active'
echo '日志检查：journalctl -u xboard-node -n 50 --no-pager'
