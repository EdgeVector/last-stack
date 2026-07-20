#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

git -c init.defaultBranch=main init --bare "$tmp/origin.git" >/dev/null
git clone "$tmp/origin.git" "$tmp/seed" >/dev/null 2>&1
git -C "$tmp/seed" config user.email test@example.com
git -C "$tmp/seed" config user.name Test
mkdir -p "$tmp/seed/bin"
cp "$ROOT/bin/last-stack-update-check" "$tmp/seed/bin/last-stack-update-check"
cp "$ROOT/VERSION" "$tmp/seed/VERSION"
printf 'initial\n' > "$tmp/seed/README.md"
git -C "$tmp/seed" add .
git -C "$tmp/seed" commit -m initial >/dev/null
git -C "$tmp/seed" push -u origin HEAD:main >/dev/null 2>&1

git clone "$tmp/origin.git" "$tmp/install" >/dev/null 2>&1
git -C "$tmp/install" checkout main >/dev/null 2>&1
version_url="file://$tmp/install/VERSION"

up_to_date="$(LASTSTACK_REMOTE_URL="$version_url" "$tmp/install/bin/last-stack-update-check")"
test "$up_to_date" = "UP_TO_DATE"

git clone "$tmp/origin.git" "$tmp/feature-install" >/dev/null 2>&1
git -C "$tmp/feature-install" checkout -b feature/parked >/dev/null 2>&1
version_url_feature="file://$tmp/feature-install/VERSION"

printf 'routine fix without version bump\n' >> "$tmp/seed/README.md"
git -C "$tmp/seed" commit -am "routine fix" >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1

stale="$(LASTSTACK_REMOTE_URL="$version_url" "$tmp/install/bin/last-stack-update-check")"
case "$stale" in
  GIT_UPDATE_AVAILABLE*) ;;
  *)
    printf 'expected GIT_UPDATE_AVAILABLE, got: %s\n' "$stale" >&2
    exit 1
    ;;
esac

stale_feature="$(LASTSTACK_REMOTE_URL="$version_url_feature" "$tmp/feature-install/bin/last-stack-update-check")"
case "$stale_feature" in
  GIT_UPDATE_AVAILABLE*"local_ref=refs/heads/feature/parked"*) ;;
  *)
    printf 'expected GIT_UPDATE_AVAILABLE for stale non-default install, got: %s\n' "$stale_feature" >&2
    exit 1
    ;;
esac

# --- lastgit venue: defaults to lastgit remote over a stale origin mirror ---
lgtmp="$(mktemp -d)"
lgcleanup() {
  rm -rf "$lgtmp"
}
trap 'lgcleanup; cleanup' EXIT

git -c init.defaultBranch=main init --bare "$lgtmp/origin-mirror.git" >/dev/null
git -c init.defaultBranch=main init --bare "$lgtmp/lastgit.git" >/dev/null
git clone "$lgtmp/lastgit.git" "$lgtmp/seed" >/dev/null 2>&1
git -C "$lgtmp/seed" config user.email test@example.com
git -C "$lgtmp/seed" config user.name Test
mkdir -p "$lgtmp/seed/bin"
cp "$ROOT/bin/last-stack-update-check" "$lgtmp/seed/bin/last-stack-update-check"
cp "$ROOT/VERSION" "$lgtmp/seed/VERSION"
printf 'initial\n' >"$lgtmp/seed/README.md"
git -C "$lgtmp/seed" add .
git -C "$lgtmp/seed" commit -m initial >/dev/null
git -C "$lgtmp/seed" push origin HEAD:main >/dev/null 2>&1
# The read-only mirror only receives the first commit.
git -C "$lgtmp/seed" push "$lgtmp/origin-mirror.git" HEAD:main >/dev/null 2>&1

git clone "$lgtmp/lastgit.git" "$lgtmp/install" >/dev/null 2>&1
mkdir -p "$lgtmp/install/.last-stack"
printf 'lastgit\n' >"$lgtmp/install/.last-stack/pr-venue"
git -C "$lgtmp/install" remote rename origin lastgit
git -C "$lgtmp/install" remote add origin "$lgtmp/origin-mirror.git"

# Advance canonical LastGit and fast-forward the install. The install is now
# ahead of the stale origin mirror but current with its venue remote.
printf 'second\n' >>"$lgtmp/seed/README.md"
git -C "$lgtmp/seed" commit -am second >/dev/null
git -C "$lgtmp/seed" push origin HEAD:main >/dev/null 2>&1
git -C "$lgtmp/install" pull --ff-only lastgit main >/dev/null 2>&1
version_url_lastgit="file://$lgtmp/install/VERSION"

stale_mirror="$(LASTSTACK_REMOTE_REPO=origin LASTSTACK_REMOTE_URL="$version_url_lastgit" "$lgtmp/install/bin/last-stack-update-check")"
test "$stale_mirror" = "UP_TO_DATE"

venue_current="$(LASTSTACK_REMOTE_URL="$version_url_lastgit" "$lgtmp/install/bin/last-stack-update-check")"
test "$venue_current" = "UP_TO_DATE"

rm -f "$lgtmp/install/.last-stack/pr-venue" "$lgtmp/install/.update-check"
without_venue="$(LASTSTACK_REMOTE_URL="$version_url_lastgit" "$lgtmp/install/bin/last-stack-update-check")"
test "$without_venue" = "UP_TO_DATE"

echo "ok"
