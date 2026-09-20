#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-safe-upgrade-readback.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/fold"
git init -q "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m candidate
oid="$(git -C "$repo" rev-parse HEAD)"

candidate="$tmp/candidate"
mkdir -p "$candidate"
printf '#!/usr/bin/env bash\nprintf "lastdbd 0.23.3-1-g%s\\n" "${oid:0:12}"\n' "$oid" >"$candidate/lastdbd"
printf '#!/usr/bin/env bash\nprintf "lastdb 0.23.3-1-g%s\\n" "${oid:0:12}"\n' "$oid" >"$candidate/lastdb"
chmod 755 "$candidate/lastdbd" "$candidate/lastdb"
printf '{"source_git_oid":"%s"}\n' "$oid" >"$candidate/manifest.json"

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping|validate|publish) exit 0 ;;
  write-probe) printf '%s\n' '{"ok":true}' ;;
  run)
    printf '%s\n' 'lx-test-readback'
    printf '%s\n' 'status: running'
    printf '%s\n' 'state: CUTOVER'
    exit 3
    ;;
  show)
    # Optional: stay `running` for the first N reads (VERIFY after a live
    # cutover), then succeed. LOOM_FAKE_RUNNING_READS counts down in a file.
    if [ -n "${LOOM_FAKE_RUNNING_READS:-}" ] && [ -f "${LOOM_FAKE_RUNNING_READS}" ]; then
      left="$(cat "$LOOM_FAKE_RUNNING_READS")"
      if [ "$left" -gt 0 ]; then
        echo $((left - 1)) >"$LOOM_FAKE_RUNNING_READS"
        printf '%s\n' 'lx-test-readback'
        printf '%s\n' 'status: running'
        printf '%s\n' 'state: CUTOVER'
        exit 0
      fi
    fi
    if [ "${LOOM_FAKE_FINAL:-succeeded}" != succeeded ]; then
      printf '%s\n' 'lx-test-readback'
      printf '%s\n' "status: ${LOOM_FAKE_FINAL}"
      printf '%s\n' 'state: CUTOVER'
      exit 0
    fi
    printf '%s\n' 'lx-test-readback'
    printf '%s\n' 'status: succeeded'
    printf '%s\n' 'state: DONE'
    ;;
  *) printf 'unexpected loom command: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod 755 "$fake_bin/loom"
mock_home="$tmp/home"
mkdir -p "$mock_home/.local/bin"
cp "$fake_bin/loom" "$mock_home/.local/bin/loom"

out="$(
  HOME="$mock_home" \
  PATH="$fake_bin:$PATH" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  LASTDB_SAFE_UPGRADE_LOOM_READBACK_SECS=2 \
  "$ROOT/bin/last-stack-safe-upgrade-loom" \
    --candidate "$candidate/lastdbd" \
    --source-git-oid "$oid" \
    --json
)"

printf '%s\n' "$out" | jq -e '
  .outcome == "ok"
  and .status == "succeeded"
  and .state == "DONE"
  and .execution == "lx-test-readback"
' >/dev/null

# The execution is still `running` past the 30 s readback window (VERIFY after
# the live cutover; measured 2026-09-20 23:24Z as a false red). The wrapper
# must keep reading while it runs, then report the success.
counter="$tmp/running-reads"
echo 3 >"$counter"
out="$(
  HOME="$mock_home" \
  PATH="$fake_bin:$PATH" \
  LOOM_FAKE_RUNNING_READS="$counter" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  LASTDB_SAFE_UPGRADE_LOOM_READBACK_SECS=1 \
  LASTDB_SAFE_UPGRADE_LOOM_RUNNING_SECS=60 \
  "$ROOT/bin/last-stack-safe-upgrade-loom" \
    --candidate "$candidate/lastdbd" \
    --source-git-oid "$oid" \
    --json
)"
printf '%s\n' "$out" | jq -e '.outcome == "ok" and .status == "succeeded" and .state == "DONE"' >/dev/null \
  || { printf 'FAIL: a still-running execution that then succeeds must read as ok: %s\n' "$out" >&2; exit 1; }
[ "$(cat "$counter")" = 0 ] || { echo "FAIL: the wrapper did not wait through the running reads" >&2; exit 1; }

# A running execution that never finishes inside the running budget is non-green.
echo 1000 >"$counter"
set +e
out="$(
  HOME="$mock_home" \
  PATH="$fake_bin:$PATH" \
  LOOM_FAKE_RUNNING_READS="$counter" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  LASTDB_SAFE_UPGRADE_LOOM_READBACK_SECS=1 \
  LASTDB_SAFE_UPGRADE_LOOM_RUNNING_SECS=3 \
  "$ROOT/bin/last-stack-safe-upgrade-loom" \
    --candidate "$candidate/lastdbd" \
    --source-git-oid "$oid" \
    --json
)"
rc=$?
set -e
[ "$rc" -eq 3 ] || { echo "FAIL: an execution still running past the budget must exit 3, got $rc" >&2; exit 1; }
printf '%s\n' "$out" | jq -e '.outcome == "error" and .status == "running"' >/dev/null \
  || { printf 'FAIL: running past budget must report status running: %s\n' "$out" >&2; exit 1; }

# A terminal failure is reported at once, without waiting the readback out.
set +e
out="$(
  HOME="$mock_home" \
  PATH="$fake_bin:$PATH" \
  LOOM_FAKE_FINAL=failed \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  LASTDB_SAFE_UPGRADE_LOOM_READBACK_SECS=30 \
  "$ROOT/bin/last-stack-safe-upgrade-loom" \
    --candidate "$candidate/lastdbd" \
    --source-git-oid "$oid" \
    --json
)"
rc=$?
set -e
[ "$rc" -eq 3 ] || { echo "FAIL: a failed execution must exit 3, got $rc" >&2; exit 1; }
printf '%s\n' "$out" | jq -e '.status == "failed"' >/dev/null \
  || { printf 'FAIL: a failed execution must read as failed: %s\n' "$out" >&2; exit 1; }

printf 'PASS: safe-upgrade Loom launcher reads back a terminal success, waits through running, reports failure\n'
