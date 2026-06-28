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
printf 'one\n' > "$tmp/seed/file.txt"
git -C "$tmp/seed" add file.txt
git -C "$tmp/seed" commit -m one >/dev/null
git -C "$tmp/seed" push -u origin HEAD:main >/dev/null 2>&1

git clone "$tmp/origin.git" "$tmp/target" >/dev/null 2>&1
git -C "$tmp/target" checkout main >/dev/null 2>&1

printf 'two\n' >> "$tmp/seed/file.txt"
git -C "$tmp/seed" commit -am two >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1

printf 'dirty\n' > "$tmp/target/dirty.txt"
before_head="$(git -C "$tmp/target" rev-parse HEAD)"
before_upstream="$(git -C "$tmp/target" rev-parse --verify -q '@{u}')"
before_status="$(git -C "$tmp/target" status --porcelain=v1 --untracked-files=all)"

if LAST_STACK_DOGFOOD_TARGET_ROOTS="$tmp/targets" \
  "$ROOT/bin/last-stack-dogfood-target-checkout" "$tmp/target" > "$tmp/no-current.out" 2>&1; then
  printf 'expected blocker without current isolated checkout\n' >&2
  exit 1
fi
grep -q $'\tresult=blocker\t' "$tmp/no-current.out"
grep -q $'\treason=no-current-isolated-checkout$' "$tmp/no-current.out"

mkdir -p "$tmp/targets"
git clone --branch main --single-branch "$tmp/origin.git" "$tmp/targets/current" >/dev/null 2>&1

resolved="$(LAST_STACK_DOGFOOD_TARGET_ROOTS="$tmp/targets" \
  "$ROOT/bin/last-stack-dogfood-target-checkout" "$tmp/target")"
grep -q $'^TARGET\t.*\tresult=stale\t' <<< "$resolved"
grep -q $'^SELECTED\tpath=.*targets/current.*\tresult=fresh\t' <<< "$resolved"
grep -q $'\tresult=ok\treason=current-isolated-checkout$' <<< "$resolved"

after_head="$(git -C "$tmp/target" rev-parse HEAD)"
after_upstream="$(git -C "$tmp/target" rev-parse --verify -q '@{u}')"
after_status="$(git -C "$tmp/target" status --porcelain=v1 --untracked-files=all)"
test "$before_head" = "$after_head"
test "$before_upstream" = "$after_upstream"
test "$before_status" = "$after_status"
test -f "$tmp/target/dirty.txt"

echo "ok"
