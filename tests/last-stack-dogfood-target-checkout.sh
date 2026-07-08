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

selected_from() {
  awk -F '\t' '
    /^RESULT\t/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^selected=/) {
          print substr($i, 10)
        }
      }
    }
  '
}

if LAST_STACK_DOGFOOD_TARGET_MANAGE=0 \
  LAST_STACK_DOGFOOD_TARGET_ROOTS="$tmp/no-managed-targets" \
  "$ROOT/bin/last-stack-dogfood-target-checkout" "$tmp/target" > "$tmp/no-current.out" 2>&1; then
  printf 'expected blocker without current isolated checkout when management is disabled\n' >&2
  exit 1
fi
grep -q $'\tresult=blocker\t' "$tmp/no-current.out"
grep -q $'\treason=no-current-isolated-checkout$' "$tmp/no-current.out"
grep -q $'^REMEDIATION\t.*\taction=create-current-isolated-checkout\t' "$tmp/no-current.out"
grep -q "$tmp/no-managed-targets/origin" "$tmp/no-current.out"

created="$(LAST_STACK_DOGFOOD_TARGET_ROOTS="$tmp/managed-targets" \
  "$ROOT/bin/last-stack-dogfood-target-checkout" "$tmp/target")"
grep -q $'^TARGET\t.*\tresult=stale\t' <<< "$created"
grep -q $'^SELECTED\tpath=.*managed-targets/origin.*\tresult=fresh\t' <<< "$created"
grep -q $'\tresult=ok\treason=current-isolated-checkout$' <<< "$created"

selected="$(selected_from <<< "$created")"
test "$selected" = "$tmp/managed-targets/origin"
test "$(git -C "$selected" rev-parse HEAD)" = "$(git -C "$tmp/origin.git" rev-parse main)"
recipe_seen="$(git -C "$selected" show HEAD:file.txt)"
grep -q '^two$' <<< "$recipe_seen"

mkdir -p "$tmp/refresh-targets"
git clone --branch main --single-branch "$tmp/origin.git" "$tmp/refresh-targets/origin" >/dev/null 2>&1

printf 'three\n' >> "$tmp/seed/file.txt"
git -C "$tmp/seed" commit -am three >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1

resolved="$(LAST_STACK_DOGFOOD_TARGET_ROOTS="$tmp/refresh-targets" \
  "$ROOT/bin/last-stack-dogfood-target-checkout" "$tmp/target")"
grep -q $'^TARGET\t.*\tresult=stale\t' <<< "$resolved"
grep -q $'^SELECTED\tpath=.*refresh-targets/origin.*\tresult=fresh\t' <<< "$resolved"
grep -q $'\tresult=ok\treason=current-isolated-checkout$' <<< "$resolved"

selected="$(selected_from <<< "$resolved")"
test "$selected" = "$tmp/refresh-targets/origin"
test "$(git -C "$selected" rev-parse HEAD)" = "$(git -C "$tmp/origin.git" rev-parse main)"

recipe_seen="$(git -C "$selected" show HEAD:file.txt)"
grep -q '^three$' <<< "$recipe_seen"

git -c init.defaultBranch=main init --bare "$tmp/other-origin.git" >/dev/null
mkdir -p "$tmp/collision-targets"
git clone --branch main --single-branch "$tmp/origin.git" "$tmp/collision-targets/origin" >/dev/null 2>&1
git -C "$tmp/collision-targets/origin" remote set-url origin "$tmp/other-origin.git"

printf 'four\n' >> "$tmp/seed/file.txt"
git -C "$tmp/seed" commit -am four >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1

collision_resolved="$(LAST_STACK_DOGFOOD_TARGET_ROOTS="$tmp/collision-targets" \
  "$ROOT/bin/last-stack-dogfood-target-checkout" "$tmp/target")"
grep -q $'^TARGET\t.*\tresult=stale\t' <<< "$collision_resolved"
grep -q $'^SELECTED\tpath=.*collision-targets.*\tresult=fresh\t' <<< "$collision_resolved"
grep -q $'\tresult=ok\treason=current-isolated-checkout$' <<< "$collision_resolved"

selected="$(selected_from <<< "$collision_resolved")"
test "$selected" != "$tmp/collision-targets/origin"
test "$(git -C "$selected" remote get-url origin)" = "$tmp/origin.git"
test "$(git -C "$selected" rev-parse HEAD)" = "$(git -C "$tmp/origin.git" rev-parse main)"

git clone "$tmp/origin.git" "$tmp/non-main-target" >/dev/null 2>&1
git -C "$tmp/non-main-target" checkout -b release/behind-main --track origin/main >/dev/null 2>&1
non_main_before_branch="$(git -C "$tmp/non-main-target" symbolic-ref --quiet --short HEAD)"
non_main_before_head="$(git -C "$tmp/non-main-target" rev-parse HEAD)"
non_main_before_status="$(git -C "$tmp/non-main-target" status --porcelain=v1 --untracked-files=all)"

printf 'five\n' >> "$tmp/seed/file.txt"
git -C "$tmp/seed" commit -am five >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1
git -C "$tmp/non-main-target" fetch origin main >/dev/null 2>&1

mkdir -p "$tmp/non-main-targets"
git clone --branch main --single-branch "$tmp/origin.git" "$tmp/non-main-targets/origin" >/dev/null 2>&1
git -C "$tmp/non-main-targets/origin" remote set-url origin "$tmp/other-origin.git"
git -C "$tmp/non-main-targets/origin" checkout HEAD~1 >/dev/null 2>&1

non_main_resolved="$(LAST_STACK_DOGFOOD_TARGET_ROOTS="$tmp/non-main-targets" \
  "$ROOT/bin/last-stack-dogfood-target-checkout" "$tmp/non-main-target")"
grep -q $'^TARGET\t.*\tbranch=release/behind-main\t.*\tresult=stale\treason=head-behind-upstream-by-1$' <<< "$non_main_resolved"
grep -q $'^SELECTED\tpath=.*non-main-targets.*\tbranch=main\t.*\tresult=fresh\t' <<< "$non_main_resolved"
grep -q $'\tresult=ok\treason=current-isolated-checkout$' <<< "$non_main_resolved"

selected="$(selected_from <<< "$non_main_resolved")"
test "$selected" != "$tmp/non-main-targets/origin"
test "$(git -C "$selected" remote get-url origin)" = "$tmp/origin.git"
test "$(git -C "$selected" rev-parse HEAD)" = "$(git -C "$tmp/origin.git" rev-parse main)"
test "$(git -C "$tmp/non-main-target" symbolic-ref --quiet --short HEAD)" = "$non_main_before_branch"
test "$(git -C "$tmp/non-main-target" rev-parse HEAD)" = "$non_main_before_head"
test "$(git -C "$tmp/non-main-target" status --porcelain=v1 --untracked-files=all)" = "$non_main_before_status"

mkdir -p "$tmp/EdgeVector"
git clone --bare "$tmp/origin.git" "$tmp/EdgeVector/fold.git" >/dev/null 2>&1
git clone "$tmp/EdgeVector/fold.git" "$tmp/unreadable-upstream-target" >/dev/null 2>&1
git -C "$tmp/unreadable-upstream-target" checkout -b agent/name-lastdb-mini >/dev/null 2>&1
unreadable_before_branch="$(git -C "$tmp/unreadable-upstream-target" symbolic-ref --quiet --short HEAD)"
unreadable_before_head="$(git -C "$tmp/unreadable-upstream-target" rev-parse HEAD)"
unreadable_before_status="$(git -C "$tmp/unreadable-upstream-target" status --porcelain=v1 --untracked-files=all)"
git -C "$tmp/unreadable-upstream-target" update-ref refs/remotes/origin/agent/name-lastdb-mini HEAD
git -C "$tmp/unreadable-upstream-target" branch --set-upstream-to=origin/agent/name-lastdb-mini >/dev/null 2>&1

printf 'fold-main\n' >> "$tmp/seed/file.txt"
git -C "$tmp/seed" commit -am fold-main >/dev/null
git -C "$tmp/seed" push "$tmp/EdgeVector/fold.git" HEAD:main >/dev/null 2>&1

unreadable_resolved="$(LAST_STACK_DOGFOOD_TARGET_ROOTS="$tmp/unreadable-managed-targets" \
  "$ROOT/bin/last-stack-dogfood-target-checkout" "$tmp/unreadable-upstream-target")"
grep -q $'^TARGET\t.*\tbranch=agent/name-lastdb-mini\t.*\tresult=unknown\treason=remote-upstream-unreadable$' <<< "$unreadable_resolved"
grep -q $'^SELECTED\tpath=.*unreadable-managed-targets/fold\tbranch=main\t.*\tresult=fresh\t' <<< "$unreadable_resolved"
grep -q $'\tresult=ok\treason=current-isolated-checkout$' <<< "$unreadable_resolved"

selected="$(selected_from <<< "$unreadable_resolved")"
test "$selected" = "$tmp/unreadable-managed-targets/fold"
test "$(git -C "$selected" rev-parse HEAD)" = "$(git -C "$tmp/EdgeVector/fold.git" rev-parse main)"
test "$(git -C "$tmp/unreadable-upstream-target" symbolic-ref --quiet --short HEAD)" = "$unreadable_before_branch"
test "$(git -C "$tmp/unreadable-upstream-target" rev-parse HEAD)" = "$unreadable_before_head"
test "$(git -C "$tmp/unreadable-upstream-target" status --porcelain=v1 --untracked-files=all)" = "$unreadable_before_status"

git clone "$tmp/origin.git" "$tmp/no-upstream-target" >/dev/null 2>&1
git -C "$tmp/no-upstream-target" checkout -b local-work main >/dev/null 2>&1
git -C "$tmp/no-upstream-target" branch --unset-upstream >/dev/null 2>&1 || true
printf 'local-only\n' > "$tmp/no-upstream-target/local.txt"

no_upstream_created="$(LAST_STACK_DOGFOOD_TARGET_ROOTS="$tmp/no-upstream-managed-targets" \
  "$ROOT/bin/last-stack-dogfood-target-checkout" "$tmp/no-upstream-target")"
grep -q $'^TARGET\t.*\tresult=unknown\treason=no-upstream$' <<< "$no_upstream_created"
grep -q $'^SELECTED\tpath=.*no-upstream-managed-targets/origin.*\tresult=fresh\t' <<< "$no_upstream_created"
grep -q $'\tresult=ok\treason=current-isolated-checkout$' <<< "$no_upstream_created"

selected="$(selected_from <<< "$no_upstream_created")"
test "$selected" = "$tmp/no-upstream-managed-targets/origin"
test "$(git -C "$selected" rev-parse HEAD)" = "$(git -C "$tmp/origin.git" rev-parse main)"
test -f "$tmp/no-upstream-target/local.txt"

after_head="$(git -C "$tmp/target" rev-parse HEAD)"
after_upstream="$(git -C "$tmp/target" rev-parse --verify -q '@{u}')"
after_status="$(git -C "$tmp/target" status --porcelain=v1 --untracked-files=all)"
test "$before_head" = "$after_head"
test "$before_upstream" = "$after_upstream"
test "$before_status" = "$after_status"
test -f "$tmp/target/dirty.txt"

echo "ok"
