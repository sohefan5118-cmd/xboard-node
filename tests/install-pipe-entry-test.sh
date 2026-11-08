#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

bash -n "$ROOT/install.sh"

cat "$ROOT/install.sh" | bash -s -- --help >"$TMP/help.out"
grep -q 'xboard-node Installer' "$TMP/help.out"
grep -q -- '--mode machine' "$TMP/help.out"

source "$ROOT/install.sh"
declare -F main >/dev/null

echo 'installer pipe entry and source guard tests passed'
