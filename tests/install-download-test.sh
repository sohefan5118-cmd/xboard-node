#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

source "$ROOT/install.sh"
TMP_DIR="$TMP"
ARCH=amd64
RELEASE_VERSION=dev
NODE_BYTES='test node artifact'
NODE_SHA=$(printf %s "$NODE_BYTES" | sha256sum | awk '{print $1}')
NODE_SHA256_AMD64="$NODE_SHA"
XBCTL_SHA256_AMD64=''

cat > "$TMP/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
out=''
url=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -H) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    */releases/download/dev/*) exit 22 ;;
    */releases/tags/dev) printf '{"assets":[{"name":"xboard-node-linux-amd64","id":42}]}' > "$out" ;;
    */releases/assets/42) printf %s "$MOCK_ASSET_CONTENT" > "$out" ;;
    *) echo "unexpected URL: $url" >&2; exit 2 ;;
esac
MOCK
chmod +x "$TMP/curl"
PATH="$TMP:$PATH"

export MOCK_ASSET_CONTENT="$NODE_BYTES"
download_release_asset xboard-node-linux-amd64 "$TMP/node"
[[ "$(cat "$TMP/node")" == "$NODE_BYTES" ]]

NODE_SHA256_AMD64='0000000000000000000000000000000000000000000000000000000000000000'
if download_release_asset xboard-node-linux-amd64 "$TMP/bad" 2>/dev/null; then
    echo 'expected checksum mismatch to fail' >&2
    exit 1
fi
[[ ! -e "$TMP/bad" ]]

echo 'download fallback and checksum tests passed'
