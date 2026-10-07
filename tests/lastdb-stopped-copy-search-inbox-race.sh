#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh"
bash -n "$SCRIPT"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh
. "$SCRIPT"

TEST_ROOT="$(mktemp -d /private/tmp/lastdb-search-inbox-copy.XXXXXX)"
home="$TEST_ROOT/home"
mkdir -p "$home/data/data" "$home/apps/search/inbox"
printf 'one record\n' >"$home/data/data/record"
printf 'identity fixture\n' >"$home/identity.key"
printf '{"paused":true}\n' >"$home/cloud_sync.json.paused"
: >"$home/.cloud_resume_required"
printf '{"version":1,"pid":1234,"start_ts":5678,"flush_ok":true}\n' \
  >"$home/.shutdown_flush_ready"

name=1791333521535_0fcf323d85bb426f9ab7d94735ae88c2.json
allowed="cp: $home/apps/search/inbox/$name: No such file or directory"
errors="$TEST_ROOT/cp-errors"
if [ "${1:-}" = reject-other-error ]; then
  printf 'cp: %s/data/data/record: No such file or directory\n' "$home" >"$errors"
  if transient_search_inbox_cp_error_count "$errors" "$home" >/dev/null; then
    echo 'FAIL: case reject-other-error' >&2; exit 1
  fi
  printf 'PASS: case reject-other-error\n'
  exit 0
fi
printf '%s\n%s\n' "$allowed" "$allowed" >"$errors"
[ "$(transient_search_inbox_cp_error_count "$errors" "$home")" = 2 ] \
  || { echo 'FAIL: case exact-search-inbox-enoent' >&2; exit 1; }

check_reject() {
  local case_name="$1" line="$2"
  [ "${3:-}" = mixed ] && printf '%s\n' "$allowed" >"$errors" || : >"$errors"
  printf '%s\n' "$line" >>"$errors"
  if transient_search_inbox_cp_error_count "$errors" "$home" >/dev/null; then
    printf 'FAIL: case %s\n' "$case_name" >&2
    exit 1
  fi
}
check_reject reject-other-error \
  "cp: $home/data/data/record: No such file or directory"
check_reject reject-mixed-error \
  "cp: $home/data/data/record: No such file or directory" mixed
check_reject reject-nested-inbox \
  "cp: $home/apps/search/inbox/done/$name: No such file or directory"
check_reject reject-other-errno \
  "cp: $home/apps/search/inbox/$name: Permission denied"
check_reject reject-other-name \
  "cp: $home/apps/search/inbox/other.json: No such file or directory"
check_reject reject-destination \
  "cp: $TEST_ROOT/copy/apps/search/inbox/$name: No such file or directory"
check_reject reject-empty-line ""
: >"$errors"
if transient_search_inbox_cp_error_count "$errors" "$home" >/dev/null; then
  echo 'FAIL: case empty-stderr' >&2; exit 1
fi

cat >"$TEST_ROOT/fake-timeout" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${4:-}" != cp ]; then
  exec "$REAL_TIMEOUT_BIN" "$@"
fi
"$REAL_TIMEOUT_BIN" "$@"
home="$6"
copy="$7"
name=1791333521535_0fcf323d85bb426f9ab7d94735ae88c2.json
case "${FAKE_CP_CASE:-}" in
  allowed)
    printf 'cp: %s/apps/search/inbox/%s: No such file or directory\n' "$home" "$name" >&2
    exit 1 ;;
  lost-data)
    unlink "$copy/data/data/record"
    printf 'cp: %s/apps/search/inbox/%s: No such file or directory\n' "$home" "$name" >&2
    exit 1 ;;
  other)
    printf 'cp: %s/data/data/record: No such file or directory\n' "$home" >&2
    exit 1 ;;
  timed-out)
    printf 'cp: %s/apps/search/inbox/%s: No such file or directory\n' "$home" "$name" >&2
    exit 124 ;;
  success-stderr)
    printf 'cp: %s/apps/search/inbox/%s: No such file or directory\n' "$home" "$name" >&2
    exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$TEST_ROOT/fake-timeout"
REAL_TIMEOUT_BIN="$(command -v gtimeout || command -v timeout)"
export REAL_TIMEOUT_BIN
before_free="$(free_kib "$home")"
FAKE_CP_CASE=allowed copy_stopped_home "$home" "$TEST_ROOT/accepted" \
  "$TEST_ROOT/fake-timeout" "$before_free" \
  >"$TEST_ROOT/accepted.out" 2>&1 \
  || { echo 'FAIL: case accepted-complete-data-copy' >&2; exit 1; }
grep -Fq 'STOPPED_COPY_CP=transient-search-inbox-move count=1' \
  "$TEST_ROOT/accepted.out" \
  || { echo 'FAIL: case accepted-count' >&2; exit 1; }
cmp -s "$home/data/data/record" "$TEST_ROOT/accepted/data/data/record" \
  || { echo 'FAIL: case accepted-record' >&2; exit 1; }

check_copy_reject() {
  local case_name="$1" case_value="$2" expected="$3"
  if FAKE_CP_CASE="$case_value" copy_stopped_home "$home" \
    "$TEST_ROOT/$case_name" "$TEST_ROOT/fake-timeout" "$before_free" \
    >"$TEST_ROOT/$case_name.out" 2>&1; then
    printf 'FAIL: case %s\n' "$case_name" >&2; exit 1
  fi
  grep -Fq "STOPPED_COPY=red reason=$expected" "$TEST_ROOT/$case_name.out" \
    || { printf 'FAIL: case %s-reason\n' "$case_name" >&2; exit 1; }
}
check_copy_reject reject-data-loss lost-data stopped-copy-data-path-or-size-mismatch
check_copy_reject reject-unrelated-cp-error other stopped-copy-failed
check_copy_reject reject-copy-timeout timed-out stopped-copy-failed
check_copy_reject reject-success-stderr success-stderr stopped-copy-unexpected-stderr

printf 'PASS: exact Search inbox race accepted; all other errors and data loss rejected\n'
