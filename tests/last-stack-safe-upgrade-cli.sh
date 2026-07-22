#!/usr/bin/env bash
# Unit-ish test for local safe-activate (no LastDB required).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ACTIVATE="$ROOT/bin/last-stack-safe-activate-cli"
UPGRADE="$ROOT/bin/last-stack-safe-upgrade-cli"
chmod +x "$ACTIVATE" "$UPGRADE"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/safe-upgrade-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOST_TRACK_APPS_ROOT="$TMP/apps"
export HOST_TRACK_STAMP_DIR="$TMP/stamps"

# Fake two versions of a toy CLI
mk_ver() {
  local id="$1" msg="$2"
  local d="$TMP/build/$id"
  mkdir -p "$d/bin"
  cat >"$d/bin/toy" <<EOF
#!/usr/bin/env bash
echo "$msg"
EOF
  chmod +x "$d/bin/toy"
  printf '%s\n' "$d"
}

v1="$(mk_ver aaa111 "v1")"
v2="$(mk_ver bbb222 "v2")"
link="$TMP/bin/toy"
mkdir -p "$TMP/bin"

"$ACTIVATE" activate --app toy --version-id aaa111 --version-dir "$v1" \
  --link "bin/toy:$link"
out="$("$link")"
[ "$out" = "v1" ] || { echo "FAIL expected v1 got $out"; exit 1; }

"$ACTIVATE" activate --app toy --version-id bbb222 --version-dir "$v2" \
  --link "bin/toy:$link"
out="$("$link")"
[ "$out" = "v2" ] || { echo "FAIL expected v2 got $out"; exit 1; }

# previous should be v1
prev="$(readlink "$HOST_TRACK_APPS_ROOT/toy/previous")"
[ "$prev" = "versions/aaa111" ] || { echo "FAIL previous=$prev"; exit 1; }

"$ACTIVATE" rollback --app toy --link "bin/toy:$link"
out="$("$link")"
[ "$out" = "v1" ] || { echo "FAIL rollback expected v1 got $out"; exit 1; }

cur="$(readlink "$HOST_TRACK_APPS_ROOT/toy/current")"
[ "$cur" = "versions/aaa111" ] || { echo "FAIL current after rollback=$cur"; exit 1; }

echo "PASS last-stack-safe-upgrade-cli (activate/rollback)"
