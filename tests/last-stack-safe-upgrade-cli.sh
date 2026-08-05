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

# Full 40-char hex ids — same shape host-track artifact invariant requires for
# local-safe previous to count as restorable.
V1_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
V2_ID="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
V_BAD="d20260804171208" # legacy timestamp-style (unrestorable)
v1="$(mk_ver "$V1_ID" "v1")"
v2="$(mk_ver "$V2_ID" "v2")"
v_bad="$(mk_ver "$V_BAD" "bad")"
link="$TMP/bin/toy"
mkdir -p "$TMP/bin"

"$ACTIVATE" activate --app toy --version-id "$V1_ID" --version-dir "$v1" \
  --link "bin/toy:$link"
out="$("$link")"
[ "$out" = "v1" ] || { echo "FAIL expected v1 got $out"; exit 1; }

"$ACTIVATE" activate --app toy --version-id "$V2_ID" --version-dir "$v2" \
  --link "bin/toy:$link"
out="$("$link")"
[ "$out" = "v2" ] || { echo "FAIL expected v2 got $out"; exit 1; }

# previous should be v1 (restorable 40-hex)
prev="$(readlink "$HOST_TRACK_APPS_ROOT/toy/previous")"
[ "$prev" = "versions/$V1_ID" ] || { echo "FAIL previous=$prev"; exit 1; }

"$ACTIVATE" rollback --app toy --link "bin/toy:$link"
out="$("$link")"
[ "$out" = "v1" ] || { echo "FAIL rollback expected v1 got $out"; exit 1; }

cur="$(readlink "$HOST_TRACK_APPS_ROOT/toy/current")"
[ "$cur" = "versions/$V1_ID" ] || { echo "FAIL current after rollback=$cur"; exit 1; }

# Pre-existing unrestorable previous is scrubbed on re-activate (same version).
ln -sfn "versions/$V_BAD" "$HOST_TRACK_APPS_ROOT/toy/previous"
"$ACTIVATE" activate --app toy --version-id "$V1_ID" --version-dir "$v1" \
  --link "bin/toy:$link"
if [ -L "$HOST_TRACK_APPS_ROOT/toy/previous" ]; then
  prev2="$(readlink "$HOST_TRACK_APPS_ROOT/toy/previous")"
  [ "$prev2" != "versions/$V_BAD" ] || {
    echo "FAIL unrestorable previous was retained: $prev2"
    exit 1
  }
fi

# Activate FROM a bad current id → must not park it as previous.
"$ACTIVATE" activate --app toy --version-id "$V_BAD" --version-dir "$v_bad" \
  --link "bin/toy:$link"
"$ACTIVATE" activate --app toy --version-id "$V1_ID" --version-dir "$v1" \
  --link "bin/toy:$link"
if [ -L "$HOST_TRACK_APPS_ROOT/toy/previous" ]; then
  prev3="$(readlink "$HOST_TRACK_APPS_ROOT/toy/previous")"
  [ "$prev3" != "versions/$V_BAD" ] || {
    echo "FAIL parked unrestorable previous $prev3"
    exit 1
  }
fi

echo "PASS last-stack-safe-upgrade-cli (activate/rollback + unrestorable previous scrub)"
