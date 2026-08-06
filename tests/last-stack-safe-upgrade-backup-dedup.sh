#!/usr/bin/env bash
# Compound prevention for papercut-safe-upgrade-probe-only-false-red-find-reusable-backup:
# first --probe-only of a brand-new candidate (no pre-cand-from-current backup) must not
# abort under set -e at REUSABLE_BACKUP="$(find_reusable_backup …)".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
driver="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"

bash -n "$driver"

grep -q '^find_reusable_backup()' "$driver" || {
  echo "FAIL: safe-upgrade must define reusable backup lookup" >&2
  exit 1
}
grep -q 'pre-"\$cand_ver"-from-"\$current_ver"-\*' "$driver" || {
  echo "FAIL: reusable backup lookup must match candidate/current version backups" >&2
  exit 1
}
grep -q 'backup_essentials_ok "\$candidate" && backup_data_is_not_live "\$candidate"' "$driver" || {
  echo "FAIL: reusable backups must pass essentials and live-alias guards" >&2
  exit 1
}
grep -q 'if \[ "\$PROBE_ONLY" -eq 1 \]; then' "$driver" || {
  echo "FAIL: same-version backup reuse must be limited to probe-only runs" >&2
  exit 1
}
grep -q 'reusing valid same-version probe backup' "$driver" || {
  echo "FAIL: safe-upgrade should log same-version backup reuse" >&2
  exit 1
}

# Only the live assignment (leading spaces, not a comment) — the function
# comment block also mentions REUSABLE_BACKUP="$(find_reusable_backup …)".
reuse_line="$(grep -nE '^[[:space:]]+REUSABLE_BACKUP="\$\(find_reusable_backup' "$driver" | head -1 | cut -d: -f1)"
copy_line="$(grep -nE '^[[:space:]]+cp -cR "\$PRIMARY_HOME" "\$BACKUP"' "$driver" | head -1 | cut -d: -f1)"
[ -n "$reuse_line" ] && [ -n "$copy_line" ] || {
  echo "FAIL: expected reusable lookup and backup copy lines (reuse=$reuse_line copy=$copy_line)" >&2
  exit 1
}
[ "$reuse_line" -lt "$copy_line" ] || {
  echo "FAIL: same-version reusable backup lookup must happen before cloning primary (reuse=$reuse_line copy=$copy_line)" >&2
  exit 1
}

# Static lock: the function body must always end with an unconditional return 0.
# The historical bug was a last-statement `[ -n "$found" ] && printf …` which
# exits 1 when found is empty — silent set -e abort on first canary contact.
fn_body="$(awk '
  /^find_reusable_backup\(\)/ { grab=1 }
  grab { print }
  grab && /^}/ { exit }
' "$driver")"
echo "$fn_body" | grep -q 'return 0' || {
  echo "FAIL: find_reusable_backup must explicitly return 0 (empty match is normal)" >&2
  exit 1
}
# Forbid the exact red-before last-statement pattern (conditional printf as exit status).
if echo "$fn_body" | grep -qE '^\s*\[ -n "\$found" \] && printf'; then
  echo "FAIL: find_reusable_backup must not use [ -n \"\$found\" ] && printf as last status" >&2
  exit 1
fi

# --- Runtime compound (red-before / green-after) ------------------------------
# Extract production helpers + find_reusable_backup into a harness that mimics
# the driver assignment under set -e, with an empty BACKUP_ROOT (first contact).
TMP="$(mktemp -d "${TMPDIR:-/tmp}/safe-upgrade-backup-dedup.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

awk '
  /^rss_mb_of_pid\(\)/ { exit }
  /^backup_essentials_ok\(\)/ { grab=1 }
  grab { print }
' "$driver" >"$TMP/fns.sh"

# Sanity: extracted the three functions we need
grep -q '^backup_essentials_ok()' "$TMP/fns.sh" || {
  echo "FAIL: could not extract backup_essentials_ok" >&2
  exit 1
}
grep -q '^backup_data_is_not_live()' "$TMP/fns.sh" || {
  echo "FAIL: could not extract backup_data_is_not_live" >&2
  exit 1
}
grep -q '^find_reusable_backup()' "$TMP/fns.sh" || {
  echo "FAIL: could not extract find_reusable_backup" >&2
  exit 1
}

# Empty backup root + live primary stubs — first contact for a never-probed version.
mkdir -p "$TMP/backups" "$TMP/primary/data"
: >"$TMP/primary/identity.key"
mkdir -p "$TMP/primary/data/data"

cat >"$TMP/empty-match-under-set-e.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
BACKUP_ROOT="$1"
PRIMARY_HOME="$2"
# shellcheck disable=SC1090
. "$3"
# Exact assignment shape used by safe-upgrade-lastdb.sh --probe-only:
REUSABLE_BACKUP="$(find_reusable_backup "0.99.0-never-probed" "0.23.0")"
# If we got here, set -e did not abort on empty match.
if [ -n "${REUSABLE_BACKUP}" ]; then
  echo "FAIL: expected empty reusable path for never-probed pair; got=$REUSABLE_BACKUP" >&2
  exit 1
fi
echo "OK_EMPTY"
EOS
chmod +x "$TMP/empty-match-under-set-e.sh"

set +e
OUT="$(bash "$TMP/empty-match-under-set-e.sh" "$TMP/backups" "$TMP/primary" "$TMP/fns.sh" 2>&1)"
RC=$?
set -e
[ "$RC" -eq 0 ] || {
  echo "FAIL: empty-match find_reusable_backup aborted under set -e (rc=$RC out=$OUT)" >&2
  exit 1
}
echo "$OUT" | grep -q 'OK_EMPTY' || {
  echo "FAIL: expected OK_EMPTY from empty-match harness; out=$OUT" >&2
  exit 1
}

# Positive path: a valid same-version probe backup is returned and assignment survives.
VALID="$TMP/backups/pre-0.99.0-never-probed-from-0.23.0-20260805T000000Z"
mkdir -p "$VALID/data/data"
: >"$VALID/identity.key"
# Must not be a symlink into live primary (backup_data_is_not_live).
set +e
OUT="$(
  bash -c '
    set -euo pipefail
    BACKUP_ROOT="$1"
    PRIMARY_HOME="$2"
    . "$3"
    REUSABLE_BACKUP="$(find_reusable_backup "0.99.0-never-probed" "0.23.0")"
    printf "FOUND=%s\n" "$REUSABLE_BACKUP"
  ' bash "$TMP/backups" "$TMP/primary" "$TMP/fns.sh" 2>&1
)"
RC=$?
set -e
[ "$RC" -eq 0 ] || {
  echo "FAIL: valid-backup path aborted under set -e (rc=$RC out=$OUT)" >&2
  exit 1
}
echo "$OUT" | grep -q "FOUND=$VALID" || {
  echo "FAIL: expected FOUND=$VALID; out=$OUT" >&2
  exit 1
}

echo "PASS last-stack-safe-upgrade-backup-dedup"
