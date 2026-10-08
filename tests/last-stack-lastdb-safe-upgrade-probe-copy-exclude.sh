#!/usr/bin/env bash
# A probe copy leaves out apps/search/inbox/done and nothing else. A copy that
# can restore the primary keeps it.
# papercut-safe-upgrade-probes-copy-search-receipts-20261007
#
# Optional $1 = one case number (1-7). Each case prints "FAIL: case N ..." so a
# mutation probe can state which case it expects to go red.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPTS="$ROOT/skills/lastdb-safe-upgrade/scripts"
GUARDS="$SCRIPTS/probe-copy-guards.sh"
DRIVER="$SCRIPTS/safe-upgrade-lastdb.sh"
WRITE_PROBE="$SCRIPTS/write-path-cow-probe.sh"
DEV_PROOF="$SCRIPTS/dev-photograph-candidate-proof.sh"
STOPPED="$SCRIPTS/stopped-home-copy.sh"
. "$GUARDS"

ONLY="${1:-}"
fail() { printf 'FAIL: case %s %s\n' "$CASE" "$*" >&2; exit 1; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
mode_of() {
  if stat --version >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/probe-copy-exclude.XXXXXX")"
trap 'chmod -R u+rwx "$tmp" 2>/dev/null || true; rm -rf "$tmp"' EXIT

# A home with the real shape: identity, data, a Search app with pending and
# processed batches, a second app, a hidden file, and decoys named like the
# excluded path in other places.
home="$tmp/home"
mkdir -p "$home/data" "$home/apps/search/inbox/done" "$home/apps/search/index" \
  "$home/apps/other" "$home/apps/search/done" "$home/data/done"
printf 'key\n' >"$home/identity.key"
printf 'store\n' >"$home/data/a.bin"
printf 'decoy-data\n' >"$home/data/done/keep.json"
printf 'decoy-search\n' >"$home/apps/search/done/keep.json"
printf 'pending\n' >"$home/apps/search/inbox/pending.json"
printf 'index\n' >"$home/apps/search/index/i.bin"
printf 'vec\n' >"$home/apps/search/vector-index.v2.bin"
printf 'other\n' >"$home/apps/other/file"
printf 'hidden\n' >"$home/.hidden"
printf 'dotdot\n' >"$home/..odd"
for i in 1 2 3 4 5; do printf 'batch %s\n' "$i" >"$home/apps/search/inbox/done/$i.json"; done
chmod 700 "$home/apps" "$home/apps/search"
chmod 750 "$home/apps/search/inbox"

CASE=1
if want 1; then
  copy="$tmp/c1"
  probe_clone_home "$home" "$copy" || fail 'clone returned non-zero'
  [ ! -e "$copy/apps/search/inbox/done" ] || fail 'copy kept apps/search/inbox/done'
  [ -f "$copy/identity.key" ] || fail 'copy lost identity.key'
  [ -f "$copy/data/a.bin" ] || fail 'copy lost data'
  cmp -s "$home/data/a.bin" "$copy/data/a.bin" || fail 'copy changed data bytes'
  [ -f "$copy/apps/search/inbox/pending.json" ] || fail 'copy lost a pending batch'
  [ -f "$copy/apps/search/index/i.bin" ] || fail 'copy lost the search index'
  [ -f "$copy/apps/search/vector-index.v2.bin" ] || fail 'copy lost the vector index'
  [ -f "$copy/apps/other/file" ] || fail 'copy lost another app'
  [ -f "$copy/.hidden" ] || fail 'copy lost a dot file'
  [ -f "$copy/..odd" ] || fail 'copy lost a double-dot file'
fi

CASE=2
if want 2; then
  copy="$tmp/c2"
  probe_clone_home "$home" "$copy" || fail 'clone returned non-zero'
  [ -f "$copy/data/done/keep.json" ] || fail 'copy dropped data/done (name match, wrong path)'
  [ -f "$copy/apps/search/done/keep.json" ] \
    || fail 'copy dropped apps/search/done (name match, wrong path)'
fi

CASE=3
if want 3; then
  copy="$tmp/c3"
  probe_clone_home "$home" "$copy" || fail 'clone returned non-zero'
  for d in apps apps/search apps/search/inbox; do
    [ "$(mode_of "$home/$d")" = "$(mode_of "$copy/$d")" ] \
      || fail "mode of $d differs: $(mode_of "$home/$d") vs $(mode_of "$copy/$d")"
  done
fi

CASE=4
if want 4; then
  copy="$tmp/c4"
  probe_clone_home "$home" "$copy" || fail 'clone returned non-zero'
  [ -d "$home/apps/search/inbox/done" ] || fail 'the clone removed done/ from the primary'
  n="$(ls -f "$home/apps/search/inbox/done" | wc -l | tr -d ' ')"
  [ "$n" = 7 ] || fail "the primary done/ changed: $n entries (want 5 files + . and ..)"
  [ -f "$home/apps/search/inbox/pending.json" ] || fail 'the primary lost a pending batch'
fi

CASE=5
if want 5; then
  copy="$tmp/c5"
  LASTDB_PROBE_COPY_FULL=1 probe_clone_home "$home" "$copy" || fail 'full clone returned non-zero'
  [ -f "$copy/apps/search/inbox/done/5.json" ] || fail 'LASTDB_PROBE_COPY_FULL=1 did not keep done/'
  [ -f "$copy/identity.key" ] || fail 'full clone lost identity.key'
fi

CASE=6
if want 6; then
  # A symlink on the way to the excluded path is copied as a link, never followed.
  real="$tmp/real-apps"
  mkdir -p "$real/search/inbox/done"
  printf 'outside\n' >"$real/search/inbox/done/x.json"
  linked="$tmp/linked-home"
  mkdir -p "$linked/data"
  printf 'key\n' >"$linked/identity.key"
  ln -s "$real" "$linked/apps"
  copy="$tmp/c6"
  probe_clone_home "$linked" "$copy" || fail 'clone returned non-zero'
  [ -L "$copy/apps" ] || fail 'a symlinked apps/ was followed instead of copied as a link'
  [ -f "$real/search/inbox/done/x.json" ] || fail 'the clone changed a file behind the link'
  [ -f "$copy/identity.key" ] || fail 'copy lost identity.key'
  # A destination that exists, or sits inside the home, is refused and untouched.
  mkdir "$tmp/exists"
  printf 'mine\n' >"$tmp/exists/f"
  if probe_clone_home "$home" "$tmp/exists"; then fail 'clone accepted an existing destination'; fi
  [ -f "$tmp/exists/f" ] || fail 'clone changed an existing destination'
  if probe_clone_home "$home" "$home/inside"; then fail 'clone accepted a destination inside the home'; fi
  [ ! -e "$home/inside" ] || fail 'clone wrote inside the primary home'
  if probe_clone_home "$home" "$home"; then fail 'clone accepted the primary as the destination'; fi
fi

CASE=7
if want 7; then
  # Only the probe callers use the helper. Every copy that can restore the
  # primary stays a full clone.
  grep -Fq 'probe_clone_home "$PRIMARY_HOME" "$copy"' "$DRIVER" \
    || fail 'the driver probe copy does not use probe_clone_home'
  grep -Fq 'probe_clone_home "$PRIMARY_HOME" "$copy"' "$WRITE_PROBE" \
    || fail 'the write-path probe copy does not use probe_clone_home'
  grep -Fq 'cp -cR "$PRIMARY_HOME" "$BACKUP"' "$DRIVER" \
    || fail 'the rollback point is no longer a full clone'
  if grep -Fq 'probe_clone_home' "$DEV_PROOF"; then
    fail 'the DEV photograph copy uses the probe exclusion'
  fi
  if grep -Fq 'probe_clone_home' "$STOPPED"; then
    fail 'the stopped-home backup copy uses the probe exclusion'
  fi
  # The scrub lines that guard every probe copy stay in place after the clone.
  grep -Fq 'probe_strip_cloud_state "$copy" "$PRIMARY_HOME"' "$DRIVER" \
    || fail 'the driver no longer scrubs cloud state after the clone'
  grep -Fq 'probe_strip_cloud_state "$copy" "$PRIMARY_HOME"' "$WRITE_PROBE" \
    || fail 'the write-path probe no longer scrubs cloud state after the clone'
fi

printf 'PASS: probe copy excludes apps/search/inbox/done only\n'
