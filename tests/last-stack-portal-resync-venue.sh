#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-portal-resync-venue"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-portal-resync-venue.XXXXXX")"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

portals="$tmp/portals"
mkdir -p "$portals/clean-repo/.portal" "$portals/stale-repo/.portal/../.last-stack"
mkdir -p "$portals/stale-repo/.last-stack"
mkdir -p "$portals/unknown-repo/.portal"

mirrors="$tmp/github-mirrors.tsv"
cat >"$mirrors" <<'EOF'
# EdgeVector LastGit/Forgejo -> GitHub read-only mirrors (test fixture)
# Format: slug	github_url	clone_path	source_url
clean-repo	https://github.com/EdgeVector/clean-repo.git	/tmp/mirrors/clean-repo	lastdb:///clean-repo
stale-repo	https://github.com/EdgeVector/stale-repo.git	/tmp/mirrors/stale-repo	lastdb:///stale-repo
EOF

# clean-repo: already matches the registry, on every field.
printf 'lastdb:///clean-repo\n' > "$portals/clean-repo/.portal/remote"
printf 'lastgit\n' > "$portals/clean-repo/.portal/venue"

# stale-repo: pre-migration Forgejo marker on all three files, the exact
# shape the 2026-09-26/27 recurrences described.
printf 'http://localhost:3300/EdgeVector/stale-repo.git\n' > "$portals/stale-repo/.portal/remote"
printf 'forgejo\n' > "$portals/stale-repo/.portal/venue"
printf 'forgejo\n' > "$portals/stale-repo/.last-stack/pr-venue"

# unknown-repo: no registry row at all (not yet migrated / not tracked).
# Must be silently skipped, never flagged and never written to.
printf 'http://localhost:3300/EdgeVector/unknown-repo.git\n' > "$portals/unknown-repo/.portal/remote"

export LAST_STACK_GITHUB_MIRRORS_TSV="$mirrors"
export LAST_STACK_PORTALS_ROOT="$portals"

# --- detect mode: reports drift, exits 1, changes nothing ---
rc=0
out="$("$BIN" 2>&1)" || rc=$?
if [ "$rc" -ne 1 ]; then
  echo "FAIL: detect mode expected exit 1, got $rc" >&2
  echo "$out" >&2
  exit 1
fi
case "$out" in
  *"STALE stale-repo .portal/remote:"*) ;;
  *) echo "FAIL: detect mode did not report the stale .portal/remote" >&2; echo "$out" >&2; exit 1 ;;
esac
case "$out" in
  *"STALE stale-repo .portal/venue:"*) ;;
  *) echo "FAIL: detect mode did not report the stale .portal/venue" >&2; echo "$out" >&2; exit 1 ;;
esac
case "$out" in
  *"STALE stale-repo .last-stack/pr-venue:"*) ;;
  *) echo "FAIL: detect mode did not report the stale .last-stack/pr-venue" >&2; echo "$out" >&2; exit 1 ;;
esac
case "$out" in
  *clean-repo*) echo "FAIL: detect mode flagged the already-clean portal" >&2; echo "$out" >&2; exit 1 ;;
esac
case "$out" in
  *unknown-repo*) echo "FAIL: detect mode flagged a portal absent from the registry" >&2; echo "$out" >&2; exit 1 ;;
esac
if [ "$(cat "$portals/stale-repo/.portal/remote")" != "http://localhost:3300/EdgeVector/stale-repo.git" ]; then
  echo "FAIL: detect mode (no --fix) mutated .portal/remote" >&2
  exit 1
fi

# --- --fix mode: heals the drift, exits 0 ---
rc=0
out="$("$BIN" --fix 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: --fix mode expected exit 0, got $rc" >&2
  echo "$out" >&2
  exit 1
fi
case "$out" in
  *"FIXED stale-repo"*) ;;
  *) echo "FAIL: --fix mode did not report FIXED stale-repo" >&2; echo "$out" >&2; exit 1 ;;
esac

if [ "$(cat "$portals/stale-repo/.portal/remote")" != "lastdb:///stale-repo" ]; then
  echo "FAIL: --fix mode left .portal/remote stale" >&2
  exit 1
fi
if [ "$(cat "$portals/stale-repo/.portal/venue")" != "lastgit" ]; then
  echo "FAIL: --fix mode left .portal/venue stale" >&2
  exit 1
fi
if [ "$(cat "$portals/stale-repo/.last-stack/pr-venue")" != "lastgit" ]; then
  echo "FAIL: --fix mode left .last-stack/pr-venue stale" >&2
  exit 1
fi
if [ -f "$portals/unknown-repo/.last-stack/pr-venue" ]; then
  echo "FAIL: --fix mode created a pr-venue file for an unknown-registry portal" >&2
  exit 1
fi
if [ "$(cat "$portals/unknown-repo/.portal/remote")" != "http://localhost:3300/EdgeVector/unknown-repo.git" ]; then
  echo "FAIL: --fix mode touched a portal absent from the registry" >&2
  exit 1
fi

# --- re-run detect mode: now clean, exits 0 ---
rc=0
out="$("$BIN" 2>&1)" || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: post-fix detect mode expected exit 0, got $rc" >&2
  echo "$out" >&2
  exit 1
fi
if [ -n "$out" ]; then
  echo "FAIL: post-fix detect mode printed output on a clean sweep" >&2
  echo "$out" >&2
  exit 1
fi

# --- single-portal mode ---
printf 'http://localhost:3300/EdgeVector/clean-repo.git\n' > "$portals/clean-repo/.portal/remote"
rc=0
out="$("$BIN" --portal "$portals/clean-repo" 2>&1)" || rc=$?
if [ "$rc" -ne 1 ]; then
  echo "FAIL: --portal mode expected exit 1 on the reintroduced drift, got $rc" >&2
  echo "$out" >&2
  exit 1
fi
case "$out" in
  *"STALE clean-repo"*) ;;
  *) echo "FAIL: --portal mode did not flag the reintroduced drift" >&2; echo "$out" >&2; exit 1 ;;
esac

echo "ok: last-stack-portal-resync-venue.sh"
