#!/usr/bin/env bash
# A candidate probe must not inherit production cloud state from a CoW copy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GUARDS="$ROOT/skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
WRITE_PROBE="$ROOT/skills/lastdb-safe-upgrade/scripts/write-path-cow-probe.sh"
DEV_PROOF="$ROOT/skills/lastdb-safe-upgrade/scripts/dev-photograph-candidate-proof.sh"
. "$GUARDS"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cloud-scrub.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
primary="$tmp/primary"
copy="$tmp/copy"
mkdir -p "$primary" "$copy"
for name in cloud_sync.json cloud_sync.json.paused cloud_sync.json.backup \
  .cloud_sync.json.tmp .cloud_resume_required .cloud_resume_requested \
  .cloud_resume_ready; do
  printf 'fixture\n' >"$primary/$name"
  cp "$primary/$name" "$copy/$name"
done
printf 'data\n' >"$copy/identity.key"

probe_strip_cloud_state "$copy" "$primary" || fail 'copy scrub failed'
for name in cloud_sync.json cloud_sync.json.paused cloud_sync.json.backup \
  .cloud_sync.json.tmp .cloud_resume_required .cloud_resume_requested \
  .cloud_resume_ready; do
  [ ! -e "$copy/$name" ] || fail "copy kept $name"
  [ -f "$primary/$name" ] || fail "primary lost $name"
done
[ -f "$copy/identity.key" ] || fail 'copy lost data'

if probe_strip_cloud_state "$primary" "$primary"; then
  fail 'guard accepted the primary as a copy'
fi
ln -s "$primary" "$tmp/primary-link"
if probe_strip_cloud_state "$tmp/primary-link" "$primary"; then
  fail 'guard accepted a link to the primary'
fi

printf 'fixture\n' >"$copy/.cloud_resume_required"
mkdir "$copy/cloud_sync.json.paused"
if probe_strip_cloud_state "$copy" "$primary"; then
  fail 'guard accepted a copied cloud directory'
fi
[ -d "$copy/cloud_sync.json.paused" ] || fail 'guard changed copied directory'

grep -Fq 'probe_strip_cloud_state "$copy" "$PRIMARY_HOME"' "$DRIVER" \
  || fail 'safe upgrade does not scrub each metrics copy'
grep -Fq 'SMOKE_SOURCE="$(clone_probe_home smoke-source)"' "$DRIVER" \
  || fail 'safe upgrade smoke does not use a scrubbed copy'
grep -Fq 'HOME="$SMOKE_HOME"' "$DRIVER" \
  || fail 'safe upgrade smoke does not use the scrubbed HOME'
grep -Fq 'probe_strip_cloud_state "$copy" "$PRIMARY_HOME"' "$WRITE_PROBE" \
  || fail 'write path probe does not scrub its copy'
for name in .cloud_resume_required .cloud_resume_requested .cloud_resume_ready; do
  grep -Fq "$name" "$DEV_PROOF" || fail "DEV photograph does not scrub $name"
done

printf 'PASS: probe cloud state scrub\n'
