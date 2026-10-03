#!/usr/bin/env bash
# Fixture proof for the cleanup-only path. No live LastDB path is opened.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd -P)"
helper="$repo/skills/lastdb-safe-upgrade/scripts/cleanup-retained-rollback.sh"
bash -n "$helper"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/safe-upgrade-retained-cleanup.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/fakebin" "$fixture/home/data/data" \
  "$fixture/home/bin-with-upload-cap" "$fixture/homebase"
uid="$(id -u)"
root="$fixture/lastdb-safe-upgrade-rollback-$uid"
base='pre-0.23.3-2528-g19065efcf-from-0.23.3-2378-gbe41e547e-20200102T224811Z'
point="$root/$base"
retained='2020-01-02T23:19:20Z'
lock="$fixture/owner.lock.d"
mkdir -p "$point/data/data" "$point/.safe-upgrade"
: >"$point/identity.key"
: >"$fixture/home/identity.key"
printf 'retained_at=%s\nttl_hours=24\ncleanup_owner=next-lastdb-safe-upgrade-run\n' \
  "$retained" >"$point/.safe-upgrade/retention"
printf '4242\n' >"$fixture/status.pid"
printf '0.23.3-2378-gbe41e547e\n' >"$fixture/status.build"
printf '0.23.3-2378-gbe41e547e\n' >"$fixture/installed.build"
printf 'Wed Jan  1 00:00:00 2020\n' >"$fixture/ps.lstart"
: >"$fixture/processes"

cat >"$fixture/fakebin/lastdb" <<'SH'
#!/usr/bin/env bash
[ "$1" = status ] || exit 2
printf 'lastdbd: running\n'
printf 'Uptime: 1d (pid %s, since 2020-01-01T00:00:00Z)\n' "$(cat "$FIX/status.pid")"
printf 'Build:  %s (daemon and CLI agree)\n' "$(cat "$FIX/status.build")"
SH
cat >"$fixture/fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-p 4242 -o lstart=') cat "$FIX/ps.lstart" ;;
  '-axo pid=,command=') cat "$FIX/processes" ;;
  *) exit 2 ;;
esac
SH
cat >"$fixture/home/bin-with-upload-cap/lastdbd" <<'SH'
#!/usr/bin/env bash
[ "$1" = --version ] || exit 2
printf 'lastdbd %s\n' "$(cat "$FIX/installed.build")"
SH
chmod +x "$fixture/fakebin/lastdb" "$fixture/fakebin/ps" \
  "$fixture/home/bin-with-upload-cap/lastdbd"

export FIX="$fixture"
export HOME="$fixture/homebase"
export LASTDB_HOME="$fixture/home"
export LASTDB_ROLLBACK_ROOT="$root"
export LASTDB_SIDEBIN_DIR="$fixture/home/bin-with-upload-cap"
export LASTDB_SAFE_UPGRADE_OWNER_LOCK_DIR="$lock"
export PATH="$fixture/fakebin:$PATH"

check() {
  bash "$helper" --point "$point" --expect-primary-pid 4242 \
    --expect-retained-at "$retained" "$@"
}
must_refuse() {
  local reason="$1"
  if check --execute >"$fixture/check.out" 2>"$fixture/check.err"; then
    printf 'FAIL: unsafe cleanup succeeded: %s\n' "$reason" >&2
    exit 1
  fi
  [ -d "$point" ] || { printf 'FAIL: unsafe cleanup removed point: %s\n' "$reason" >&2; exit 1; }
}

check >"$fixture/check.out"
grep -q '^CHECK ONLY:' "$fixture/check.out"
[ -d "$point" ] || { echo 'FAIL: read-only check removed point' >&2; exit 1; }
[ ! -e "$lock" ] || { echo 'FAIL: read-only check kept the owner lock' >&2; exit 1; }
if bash "$helper" --point "$point" --expect-primary-pid 4242 \
    --expect-retained-at '2020-01-02T23:19:21Z' --execute \
    >"$fixture/check.out" 2>"$fixture/check.err"; then
  echo 'FAIL: wrong retention timestamp passed cleanup' >&2
  exit 1
fi
[ -d "$point" ] || { echo 'FAIL: wrong timestamp removed point' >&2; exit 1; }
mkdir "$root/not-a-safe-upgrade-point"
if bash "$helper" --point "$root/not-a-safe-upgrade-point" \
    --expect-primary-pid 4242 --expect-retained-at "$retained" --execute \
    >"$fixture/check.out" 2>"$fixture/check.err"; then
  echo 'FAIL: unrelated path passed cleanup' >&2
  exit 1
fi
[ -d "$root/not-a-safe-upgrade-point" ] \
  || { echo 'FAIL: unrelated path was removed' >&2; exit 1; }

printf '9999\n' >"$fixture/status.pid"
must_refuse 'primary PID changed'
printf '4242\n' >"$fixture/status.pid"
printf 'candidate-build\n' >"$fixture/status.build"
must_refuse 'primary build changed'
printf '0.23.3-2378-gbe41e547e\n' >"$fixture/status.build"
printf 'candidate-build\n' >"$fixture/installed.build"
must_refuse 'installed daemon changed before a restart'
printf '0.23.3-2378-gbe41e547e\n' >"$fixture/installed.build"
printf 'Fri Jan  3 00:00:00 2020\n' >"$fixture/ps.lstart"
must_refuse 'primary restarted after clone'
printf 'Wed Jan  1 00:00:00 2020\n' >"$fixture/ps.lstart"
printf '999 lastdbd --data-dir /tmp/lastdb-safe-upgrade.probe/copy\n' >"$fixture/processes"
must_refuse 'active probe node'
: >"$fixture/processes"
printf 'unexpected=1\n' >>"$point/.safe-upgrade/retention"
must_refuse 'marker has extra data'
printf 'retained_at=%s\nttl_hours=24\ncleanup_owner=next-lastdb-safe-upgrade-run\n' \
  "$retained" >"$point/.safe-upgrade/retention"

mv "$point" "$root/held-point"
ln -s "$root/held-point" "$point"
if check --execute >"$fixture/check.out" 2>"$fixture/check.err"; then
  echo 'FAIL: symlink point passed cleanup' >&2
  exit 1
fi
[ -d "$root/held-point" ] || { echo 'FAIL: symlink target was removed' >&2; exit 1; }
rm -f "$point"
mv "$root/held-point" "$point"

mkdir "$lock"
printf '%s\n' "$$" >"$lock/pid"
printf 'pid=%s\ntoken=other\n' "$$" >"$lock/owner"
must_refuse 'active safe-upgrade owner lock'
rm -f "$lock/pid" "$lock/owner"
rmdir "$lock"

bystander="$root/hand-owned"
mkdir "$bystander"
check --execute >"$fixture/check.out"
grep -q '^RELEASED:' "$fixture/check.out"
[ ! -e "$point" ] || { echo 'FAIL: exact point was not released' >&2; exit 1; }
[ -d "$bystander" ] || { echo 'FAIL: bystander was removed' >&2; exit 1; }

echo 'PASS last-stack-safe-upgrade-retained-cleanup'
