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

fresh="$("$ROOT/bin/last-stack-git-checkout-freshness" "$tmp/target")"
printf '%s\n' "$fresh" | grep -q $'\tresult=fresh\t'

printf 'two\n' >> "$tmp/seed/file.txt"
git -C "$tmp/seed" commit -am two >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1

stale="$("$ROOT/bin/last-stack-git-checkout-freshness" "$tmp/target")"
printf '%s\n' "$stale" | grep -q $'\tresult=stale\t'
printf '%s\n' "$stale" | grep -q $'\treason=remote-upstream-advanced-without-local-fetch$'

printf 'dirty\n' > "$tmp/target/dirty.txt"
dirty="$("$ROOT/bin/last-stack-git-checkout-freshness" "$tmp/target")"
printf '%s\n' "$dirty" | grep -q $'\tdirty=yes\t'
test -f "$tmp/target/dirty.txt"

echo "ok"
