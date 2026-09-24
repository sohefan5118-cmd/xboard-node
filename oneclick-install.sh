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
: "${INSTALLER_URL:=https://raw.githubusercontent.com/sohefan5118-cmd/xboard-node/dev/install.sh}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates redis-tools >/dev/null

say '测试共享 Redis 连通性...'
PONG=$(redis-cli --no-auth-warning -h "${REDIS_ADDR%:*}" -p "${REDIS_ADDR##*:}" -a "$REDIS_PASS" PING 2>/dev/null || true)
[[ $PONG == PONG ]] || die "Redis 测试失败：$PONG（检查 A 的监听、防火墙、地址和密码）"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
say '下载并执行官方安装器...'
curl --fail --proto '=https' --tlsv1.2 -fsSL \
  "$INSTALLER_URL" \
  -o "$TMP/install.sh"
chmod 700 "$TMP/install.sh"
bash "$TMP/install.sh" --mode "$MODE" --panel "$PANEL" --token "$TOKEN" "${ARG_ID[@]}" --yes

CRED=/etc/xboard-node/credentials.env
[[ -f $CRED ]] || die "安装完成但找不到 $CRED"
chmod 600 "$CRED"
# 删除旧值后追加，重复执行本脚本不会产生重复配置。
tmp_cred=$(mktemp "${CRED}.XXXXXX")
chmod 600 "$tmp_cred"
awk -F= '!/^(DEVICE_CLAIM_ENABLED|DEVICE_CLAIM_TYPE|DEVICE_CLAIM_ADDR|DEVICE_CLAIM_PASSWORD|DEVICE_CLAIM_DB|DEVICE_CLAIM_PREFIX|DEVICE_CLAIM_TTL)=/' "$CRED" >"$tmp_cred"
cat >>"$tmp_cred" <<EOF
DEVICE_CLAIM_ENABLED=true
DEVICE_CLAIM_TYPE=redis
DEVICE_CLAIM_ADDR=$REDIS_ADDR
DEVICE_CLAIM_PASSWORD=$REDIS_PASS
DEVICE_CLAIM_DB=0
DEVICE_CLAIM_PREFIX=$CLAIM_PREFIX
DEVICE_CLAIM_TTL=$CLAIM_TTL
EOF
mv -f "$tmp_cred" "$CRED"
chmod 600 "$CRED"

systemctl daemon-reload
systemctl restart xboard-node.service
sleep 2
systemctl is-active --quiet xboard-node.service || {
  journalctl -u xboard-node.service -n 50 --no-pager
  die 'xboard-node 启动失败'
}

say '安装成功'
echo "面板: $PANEL"
echo "模式: $MODE / ID: $IDENT"
echo "Redis: $REDIS_ADDR"
echo '服务: active'
echo '日志检查：journalctl -u xboard-node -n 50 --no-pager'
