#!/usr/bin/env bash
# Unit tests for lastdb-safe-upgrade lastdb/lastdbd binary-pair gates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/binary-pair-checks.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"

[ -f "$CHECKS" ] || { echo "FAIL: missing $CHECKS" >&2; exit 1; }
[ -f "$DRIVER" ] || { echo "FAIL: missing $DRIVER" >&2; exit 1; }
bash -n "$CHECKS"
bash -n "$DRIVER"

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/binary-pair-checks.sh
. "$CHECKS"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/safe-upgrade-pair.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mk_bin() {
  local path="$1" name="$2" ver="$3"
  cat >"$path" <<EOF
#!/usr/bin/env bash
printf '%s %s\\n' "$name" "$ver"
EOF
  chmod +x "$path"
}

mkdir -p "$TMP/cand"
mk_bin "$TMP/cand/lastdbd" lastdbd "0.50.0-1-gabcdef123"
mk_bin "$TMP/cand/lastdb" lastdb "0.50.0-1-gabcdef123"

[ "$(lastdb_sibling_cli_for_daemon "$TMP/cand/lastdbd")" = "$TMP/cand/lastdb" ] || {
  echo "FAIL: sibling CLI path not next to daemon" >&2
  exit 1
}

OUT="$(assert_lastdb_binary_pair_ok "$TMP/cand/lastdbd" "$TMP/cand/lastdb" "0.50.0-1-gabcdef123" "candidate artifact")"
echo "$OUT" | grep -q 'OK: candidate artifact lastdb/lastdbd version 0.50.0-1-gabcdef123' || {
  echo "FAIL: matching pair should pass; out=$OUT" >&2
  exit 1
}

rm -f "$TMP/cand/lastdb"
set +e
OUT="$(assert_lastdb_binary_pair_ok "$TMP/cand/lastdbd" "$TMP/cand/lastdb" "0.50.0-1-gabcdef123" "candidate artifact" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: missing CLI should fail" >&2; exit 1; }
echo "$OUT" | grep -q 'missing sibling lastdb CLI' || {
  echo "FAIL: missing CLI failure should be explicit; out=$OUT" >&2
  exit 1
}

mk_bin "$TMP/cand/lastdb" lastdb "0.49.9-1-g000000000"
set +e
OUT="$(assert_lastdb_binary_pair_ok "$TMP/cand/lastdbd" "$TMP/cand/lastdb" "0.50.0-1-gabcdef123" "candidate artifact" 2>&1)"
RC=$?
set -e
[ "$RC" -ne 0 ] || { echo "FAIL: version-skewed CLI should fail" >&2; exit 1; }
echo "$OUT" | grep -q 'lastdb CLI version (0.49.9-1-g000000000) != expected lastdbd version (0.50.0-1-gabcdef123)' || {
  echo "FAIL: skew failure should name both versions; out=$OUT" >&2
  exit 1
}

grep -q 'binary-pair-checks.sh' "$DRIVER" || {
  echo "FAIL: driver must source binary-pair-checks.sh" >&2
  exit 1
}
grep -q 'assert_lastdb_binary_pair_ok "$CANDIDATE_BIN" "$CANDIDATE_CLI_BIN"' "$DRIVER" || {
  echo "FAIL: driver must gate the candidate artifact pair" >&2
  exit 1
}
grep -q 'assert_lastdb_binary_pair_ok .*installed live pair' "$DRIVER" || {
  echo "FAIL: driver must post-check the installed live pair" >&2
  exit 1
}
grep -q 'installed candidate into .*{lastdb,lastdbd}' "$DRIVER" || {
  echo "FAIL: sidebin install must install both lastdb and lastdbd" >&2
  exit 1
}

echo "PASS last-stack-lastdb-safe-upgrade-binary-pair"
