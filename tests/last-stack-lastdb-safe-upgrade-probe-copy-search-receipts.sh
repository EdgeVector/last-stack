#!/usr/bin/env bash
# A probe copy excludes only Search's completed receipts before file copy.
# The fixture uses a small fake home and never reads the primary.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
guards="$root/skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh"
driver="$root/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
write_probe="$root/skills/lastdb-safe-upgrade/scripts/write-path-cow-probe.sh"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh
# shellcheck disable=SC1091
. "$guards"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash -n "$guards" "$driver" "$write_probe"
# shellcheck disable=SC2016
grep -Fq 'probe_clone_home_without_search_receipts "$PRIMARY_HOME" "$copy"' "$driver" \
  || fail 'safe-upgrade metrics probes do not use the receipt-free copy'
# shellcheck disable=SC2016
grep -Fq 'probe_clone_home_without_search_receipts "$PRIMARY_HOME" "$copy"' "$write_probe" \
  || fail 'write-path probe does not use the receipt-free copy'

tmp="$(mktemp -d "${TMPDIR:-/private/tmp}/probe-search-receipts.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
source_home="$tmp/source"
copy_home="$tmp/copy"
mkdir -p "$source_home/data" "$source_home/apps/search/inbox/done" \
  "$source_home/apps/search/inbox/pending" \
  "$source_home/apps/search/inbox/done-extra" \
  "$source_home/apps/other/inbox/done" "$tmp/bin"
printf 'identity\n' >"$source_home/identity.key"
printf 'database\n' >"$source_home/data/atom"
printf 'receipt\n' >"$source_home/apps/search/inbox/done/receipt.json"
printf 'pending\n' >"$source_home/apps/search/inbox/pending/item.json"
printf 'nearby\n' >"$source_home/apps/search/inbox/done-extra/item.json"
printf 'other app\n' >"$source_home/apps/other/inbox/done/item.json"
printf 'hidden\n' >"$source_home/.hidden"
printf 'hidden queue state\n' >"$source_home/apps/search/inbox/.queue-state"
printf 'search state\n' >"$source_home/apps/search/state"

# Record each cp source. A copy of an ancestor would traverse the receipts
# even if a later step removed them from the result.
cat >"$tmp/bin/cp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >>"$PROBE_CP_TRACE"
exec /bin/cp "$@"
EOF
chmod 700 "$tmp/bin/cp"
export PROBE_CP_TRACE="$tmp/cp-sources"
PATH="$tmp/bin:$PATH" probe_clone_home_without_search_receipts "$source_home" "$copy_home" \
  || fail 'probe copy failed'

[ ! -e "$copy_home/apps/search/inbox/done" ] \
  || fail 'search receipts copied'
for relative in identity.key data/atom apps/search/inbox/pending/item.json \
  apps/search/inbox/done-extra/item.json apps/other/inbox/done/item.json \
  apps/search/inbox/.queue-state apps/search/state .hidden; do
  cmp -s "$source_home/$relative" "$copy_home/$relative" \
    || fail "probe copy lost or changed $relative"
done
[ -f "$source_home/apps/search/inbox/done/receipt.json" ] \
  || fail 'probe copy changed the source receipt'
if stat --version >/dev/null 2>&1; then
  copy_mode="$(stat -c '%a' "$copy_home")"
else
  copy_mode="$(stat -f '%Lp' "$copy_home")"
fi
[ "$copy_mode" = 700 ] \
  || fail 'probe home is not private'
while IFS= read -r copied_source; do
  case "$copied_source" in
    "$source_home/apps"|"$source_home/apps/search"|\
    "$source_home/apps/search/inbox"|"$source_home/apps/search/inbox/done")
      fail 'receipt subtree traversed before exclusion'
      ;;
  esac
done <"$PROBE_CP_TRACE"

printf '%s\n' 'ok: probe copy excludes only completed Search receipts before cp'
