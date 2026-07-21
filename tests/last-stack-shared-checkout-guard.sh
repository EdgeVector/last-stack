#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ws="$tmp/ws"
repo="$ws/example"
remote="$tmp/origin.git"
mkdir -p "$repo" "$tmp/bin"

git -C "$repo" init --quiet -b main
git -C "$repo" config user.name "Guard Test"
git -C "$repo" config user.email "guard@example.invalid"
printf 'base\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit --quiet -m init
git -C "$tmp" init --quiet --bare origin.git
git -C "$repo" remote add origin "$remote"
git -C "$repo" push --quiet -u origin main

# Existing repo-specific hook behavior must survive the managed prelude.
mkdir -p "$repo/.git/hooks"
printf '#!/usr/bin/env bash\nprintf existing-hook-ran >"%s"\n' "$tmp/existing-hook-ran" \
  > "$repo/.git/hooks/pre-commit"
chmod +x "$repo/.git/hooks/pre-commit"

cp "$ROOT/bin/last-stack-shared-checkout-guard" "$tmp/bin/last-stack-shared-checkout-guard"
chmod +x "$tmp/bin/last-stack-shared-checkout-guard"
LAST_STACK_SHARED_WORKSPACE="$ws" \
LAST_STACK_SHARED_GUARD="$tmp/bin/last-stack-shared-checkout-guard" \
  "$ROOT/bin/last-stack-install-shared-checkout-guards" "$ws" >/dev/null

printf 'ambient\n' >> "$repo/README.md"
git -C "$repo" add README.md
if LAST_STACK_SHARED_WORKSPACE="$ws" git -C "$repo" commit -m ambient >"$tmp/commit.out" 2>&1; then
  echo "expected ambient commit to be rejected" >&2
  exit 1
fi
grep -q 'BLOCKED_SHARED_CHECKOUT action=pre-commit' "$tmp/commit.out"
git -C "$repo" restore --staged README.md
git -C "$repo" restore README.md

worktree="$tmp/isolated"
git -C "$repo" worktree add --quiet -b feature/test "$worktree" main
printf 'isolated\n' >> "$worktree/README.md"
git -C "$worktree" add README.md
LAST_STACK_SHARED_WORKSPACE="$ws" git -C "$worktree" commit --quiet -m isolated

printf 'recovery\n' >> "$repo/README.md"
git -C "$repo" add README.md
LAST_STACK_SHARED_WORKSPACE="$ws" LAST_STACK_ALLOW_SHARED_CHECKOUT_WRITE=1 \
  git -C "$repo" commit --quiet -m recovery
test -f "$tmp/existing-hook-ran"

if LAST_STACK_SHARED_WORKSPACE="$ws" git -C "$repo" push origin main >"$tmp/push.out" 2>&1; then
  echo "expected ambient push to be rejected" >&2
  exit 1
fi
grep -q 'BLOCKED_SHARED_CHECKOUT action=pre-push' "$tmp/push.out"

LAST_STACK_SHARED_WORKSPACE="$ws" \
  "$ROOT/bin/last-stack-install-shared-checkout-guards" --audit "$ws" \
  | grep -q 'result=ok'

echo "ok last-stack-shared-checkout-guard"
