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

echo "ok"
