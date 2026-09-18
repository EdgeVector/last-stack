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

printf 'PASS: safe-upgrade Loom launcher reads back a terminal success\n'
