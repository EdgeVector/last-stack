#!/usr/bin/env bash
set -euo pipefail

# Host shells often export LASTSTACK_REMOTE_REPO=lastgit for the real install;
# this harness uses bare `origin` remotes, so clear venue overrides.
unset LASTSTACK_REMOTE_REPO LASTSTACK_REMOTE_URL LASTSTACK_SELF_UPGRADE_SKIP \
  LASTSTACK_ROUTINE_SKIP_UPDATE_CHECK 2>/dev/null || true

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

mkdir -p "$tmp/seed/bin" "$tmp/seed/routines"
cp "$ROOT/bin/last-stack-update-check" "$tmp/seed/bin/last-stack-update-check"
cp "$ROOT/bin/last-stack-self-upgrade" "$tmp/seed/bin/last-stack-self-upgrade"
cp "$ROOT/bin/last-stack-routine-read" "$tmp/seed/bin/last-stack-routine-read"
chmod +x "$tmp/seed/bin/"*
cp "$ROOT/VERSION" "$tmp/seed/VERSION"
# Minimal setup stub so self-upgrade can re-run it.
cat >"$tmp/seed/setup" <<'EOF'
#!/bin/sh
echo "setup-ok" >"$(dirname "$0")/.setup-ran"
EOF
chmod +x "$tmp/seed/setup"
printf 'name: demo\n' >"$tmp/seed/routines/demo.md"
printf 'initial\n' >"$tmp/seed/README.md"
git -C "$tmp/seed" add .
git -C "$tmp/seed" commit -m initial >/dev/null
git -C "$tmp/seed" push -u origin HEAD:main >/dev/null 2>&1

git clone "$tmp/origin.git" "$tmp/install" >/dev/null 2>&1
git -C "$tmp/install" checkout main >/dev/null 2>&1
chmod +x "$tmp/install/bin/"* "$tmp/install/setup"

# --- up-to-date ---
out="$("$tmp/install/bin/last-stack-self-upgrade" --reason=test)"
case "$out" in
  *"result=up-to-date"*) ;;
  *)
    printf 'expected up-to-date, got:\n%s\n' "$out" >&2
    exit 1
    ;;
esac

# --- dirty refuses ---
printf 'local edit\n' >>"$tmp/install/README.md"
if "$tmp/install/bin/last-stack-self-upgrade" --reason=test >/tmp/self-upgrade-dirty.out 2>/tmp/self-upgrade-dirty.err; then
  echo "expected dirty self-upgrade to fail" >&2
  exit 1
fi
grep -q 'result=error-dirty' /tmp/self-upgrade-dirty.out
git -C "$tmp/install" checkout -- README.md

# --- stale: upgrade pulls + setup ---
printf 'routine fix without version bump\n' >>"$tmp/seed/README.md"
printf 'name: demo\ncadence: hourly\nupdated: yes\n' >"$tmp/seed/routines/demo.md"
git -C "$tmp/seed" commit -am "routine fix" >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1

old_head="$(git -C "$tmp/install" rev-parse --short=12 HEAD)"
out="$("$tmp/install/bin/last-stack-self-upgrade" --reason=test)"
case "$out" in
  *"result=upgraded"*"local_head=$old_head"*) ;;
  *)
    printf 'expected upgraded, got:\n%s\n' "$out" >&2
    exit 1
    ;;
esac
test -f "$tmp/install/.setup-ran"
grep -q 'updated: yes' "$tmp/install/routines/demo.md"

# --- stale with content-equivalent dirt: repair metadata + setup ---
rm -f "$tmp/install/.setup-ran"
printf 'prewritten remote content\n' >>"$tmp/seed/README.md"
printf 'name: extra\n' >"$tmp/seed/routines/extra.md"
git -C "$tmp/seed" add .
git -C "$tmp/seed" commit -m "content equivalent routine add" >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1

old_head="$(git -C "$tmp/install" rev-parse --short=12 HEAD)"
cp "$tmp/seed/README.md" "$tmp/install/README.md"
cp "$tmp/seed/routines/extra.md" "$tmp/install/routines/extra.md"
test -n "$(git -C "$tmp/install" status --porcelain)"
out="$("$tmp/install/bin/last-stack-self-upgrade" --reason=test)"
case "$out" in
  *"result=upgraded"*"local_head=$old_head"*"note=content-equivalent-dirty"*) ;;
  *)
    printf 'expected content-equivalent dirty upgrade, got:\n%s\n' "$out" >&2
    exit 1
    ;;
esac
test -f "$tmp/install/.setup-ran"
test -z "$(git -C "$tmp/install" status --porcelain --untracked-files=no)"
git -C "$tmp/install" ls-files --error-unmatch routines/extra.md >/dev/null

# --- stale with generated local-state conflict: quarantine, then upgrade ---
rm -f "$tmp/install/.setup-ran"
mkdir -p "$tmp/seed/proofs" "$tmp/install/proofs"
printf 'remote proof template\n' >"$tmp/seed/proofs/report.md"
git -C "$tmp/seed" add proofs/report.md
git -C "$tmp/seed" commit -m "add tracked proof template" >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1

old_head="$(git -C "$tmp/install" rev-parse --short=12 HEAD)"
printf 'local generated proof\n' >"$tmp/install/proofs/report.md"
quarantine_dir="$tmp/quarantine"
out="$(LASTSTACK_SELF_UPGRADE_QUARANTINE_DIR="$quarantine_dir" "$tmp/install/bin/last-stack-self-upgrade" --reason=test)"
case "$out" in
  *"result=local-state-quarantined"*"result=upgraded"*"local_head=$old_head"*) ;;
  *)
    printf 'expected generated local-state quarantine + upgrade, got:\n%s\n' "$out" >&2
    exit 1
    ;;
esac
grep -q 'remote proof template' "$tmp/install/proofs/report.md"
grep -R -q 'local generated proof' "$quarantine_dir"
test -f "$tmp/install/.setup-ran"

# --- stale with unknown untracked conflict: still fails closed ---
printf 'remote source\n' >"$tmp/seed/local-source.txt"
git -C "$tmp/seed" add local-source.txt
git -C "$tmp/seed" commit -m "add source path" >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1
printf 'local source\n' >"$tmp/install/local-source.txt"
if "$tmp/install/bin/last-stack-self-upgrade" --reason=test >/tmp/self-upgrade-untracked.out 2>/tmp/self-upgrade-untracked.err; then
  echo "expected unknown untracked conflict to fail" >&2
  exit 1
fi
grep -q 'dirty_count=untracked-conflict' /tmp/self-upgrade-untracked.out
rm -f "$tmp/install/local-source.txt"
"$tmp/install/bin/last-stack-self-upgrade" --reason=test >/dev/null

# --- routine-read auto-heals when stale ---
# Put install behind again.
printf 'second fix\n' >>"$tmp/seed/README.md"
git -C "$tmp/seed" commit -am "second fix" >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1

# Force update-check to see remote via real git (no VERSION cache path needed).
prompt="$("$tmp/install/bin/last-stack-routine-read" demo)"
case "$prompt" in
  *"updated: yes"*) ;;
  *)
    printf 'expected routine body after auto-heal, got:\n%s\n' "$prompt" >&2
    exit 1
    ;;
esac

# --- fetch fails while ls-remote shows remote ahead → error-fetch (not soft up-to-date) ---
printf 'fetch fail fixture\n' >>"$tmp/seed/README.md"
git -C "$tmp/seed" commit -am "ahead for fetch-fail" >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1
# Break the origin remote URL so fetch fails, but leave a usable origin/main
# ref from a prior successful fetch so ls-remote fallback still sees ahead.
git -C "$tmp/install" fetch origin >/dev/null 2>&1 || true
git -C "$tmp/install" remote set-url origin "$tmp/origin.git.DOES_NOT_EXIST"
if "$tmp/install/bin/last-stack-self-upgrade" --reason=test >/tmp/self-upgrade-error-fetch.out 2>/tmp/self-upgrade-error-fetch.err; then
  echo "expected error-fetch when behind but fetch broken" >&2
  cat /tmp/self-upgrade-error-fetch.out /tmp/self-upgrade-error-fetch.err >&2 || true
  exit 1
fi
grep -q 'result=error-fetch' /tmp/self-upgrade-error-fetch.out
grep -q 'note=fetch-failed' /tmp/self-upgrade-error-fetch.out
grep -q 'git fetch' /tmp/self-upgrade-error-fetch.err
# Restore origin for remaining tests.
git -C "$tmp/install" remote set-url origin "$tmp/origin.git"
"$tmp/install/bin/last-stack-self-upgrade" --reason=test >/dev/null

# --- skip flag still fails closed ---
printf 'third fix\n' >>"$tmp/seed/README.md"
git -C "$tmp/seed" commit -am "third fix" >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1
if LASTSTACK_SELF_UPGRADE_SKIP=1 "$tmp/install/bin/last-stack-routine-read" demo >/dev/null 2>/tmp/self-upgrade-skip.err; then
  echo "expected SKIP self-upgrade to keep routine-read stale" >&2
  exit 1
fi
grep -q 'LAST_STACK_ROUTINE_STALE' /tmp/self-upgrade-skip.err

# --- routine-read stale failure is actionable when tracked dirt blocks auto-heal ---
printf 'dirty local install edit\n' >>"$tmp/install/README.md"
if LASTSTACK_ROUTINE_READ_LOCK_ATTEMPTS=1 LASTSTACK_ROUTINE_READ_LOCK_BACKOFF_S=0 \
  "$tmp/install/bin/last-stack-routine-read" demo >/tmp/self-upgrade-dirty-read.out 2>/tmp/self-upgrade-dirty-read.err; then
  echo "expected dirty stale install to fail closed" >&2
  exit 1
fi
grep -q 'LAST_STACK_ROUTINE_STALE' /tmp/self-upgrade-dirty-read.err
grep -q 'LAST_STACK_ROUTINE_CONTEXT routine=demo root=.*/install' /tmp/self-upgrade-dirty-read.err
grep -q 'LAST_STACK_ROUTINE_DETAIL_BEGIN' /tmp/self-upgrade-dirty-read.err
grep -q 'result=error-dirty' /tmp/self-upgrade-dirty-read.err
grep -q 'dirty_count=1' /tmp/self-upgrade-dirty-read.err
grep -q 'sample= M README.md' /tmp/self-upgrade-dirty-read.err
grep -q 'LAST_STACK_ROUTINE_REMEDIATION inspect: cd ".*/install"' /tmp/self-upgrade-dirty-read.err
grep -q 'LAST_STACK_ROUTINE_REMEDIATION clean-upgrade:' /tmp/self-upgrade-dirty-read.err
grep -q 'LAST_STACK_ROUTINE_REMEDIATION dirty-tree:' /tmp/self-upgrade-dirty-read.err
git -C "$tmp/install" checkout -- README.md

# --- routine-read defers when self-upgrade cannot fetch and install stays stale ---
# Soft path (legacy note=fetch-failed with exit 0 still defer when still stale).
cp "$tmp/install/bin/last-stack-self-upgrade" "$tmp/install/bin/last-stack-self-upgrade.real"
cat >"$tmp/install/bin/last-stack-self-upgrade" <<'EOF'
#!/bin/sh
echo "LAST_STACK_SELF_UPGRADE reason=routine-read result=up-to-date local_head=stub note=fetch-failed"
exit 0
EOF
chmod +x "$tmp/install/bin/last-stack-self-upgrade"
rm -f "$tmp/install/state/self-upgrade-fetch-fail.count"
if LASTSTACK_ROUTINE_READ_LOCK_ATTEMPTS=1 LASTSTACK_ROUTINE_READ_LOCK_BACKOFF_S=0 \
  LASTSTACK_FETCH_FAIL_STATE_DIR="$tmp/install/state" \
  "$tmp/install/bin/last-stack-routine-read" demo >/tmp/self-upgrade-fetch.out 2>/tmp/self-upgrade-fetch.err; then
  echo "expected fetch-failed stale install to defer routine-read" >&2
  exit 1
fi
grep -q 'LAST_STACK_ROUTINE_DEFERRED self_upgrade_fetch_failed' /tmp/self-upgrade-fetch.err
grep -q 'note=fetch-failed' /tmp/self-upgrade-fetch.err
grep -q 'streak=1' /tmp/self-upgrade-fetch.err
if grep -q 'LAST_STACK_ROUTINE_STALE' /tmp/self-upgrade-fetch.err; then
  echo "expected fetch-failed stale install to avoid stale failure classification" >&2
  exit 1
fi

# error-fetch (exit 1) also defers, not hard-stale, so blips stay soft.
cat >"$tmp/install/bin/last-stack-self-upgrade" <<'EOF'
#!/bin/sh
echo "LAST_STACK_SELF_UPGRADE reason=routine-read result=error-fetch local_head=stub remote_head=deadbeef note=fetch-failed"
exit 1
EOF
chmod +x "$tmp/install/bin/last-stack-self-upgrade"
if LASTSTACK_ROUTINE_READ_LOCK_ATTEMPTS=1 LASTSTACK_ROUTINE_READ_LOCK_BACKOFF_S=0 \
  LASTSTACK_FETCH_FAIL_STATE_DIR="$tmp/install/state" \
  LASTSTACK_FETCH_FAIL_SOFT_MAX=3 \
  "$tmp/install/bin/last-stack-routine-read" demo >/tmp/self-upgrade-fetch2.out 2>/tmp/self-upgrade-fetch2.err; then
  echo "expected error-fetch to defer routine-read" >&2
  exit 1
fi
grep -q 'LAST_STACK_ROUTINE_DEFERRED self_upgrade_fetch_failed' /tmp/self-upgrade-fetch2.err
grep -q 'streak=2' /tmp/self-upgrade-fetch2.err

# After soft_max consecutive fetch fails → escalate signal (still exit 75).
if LASTSTACK_ROUTINE_READ_LOCK_ATTEMPTS=1 LASTSTACK_ROUTINE_READ_LOCK_BACKOFF_S=0 \
  LASTSTACK_FETCH_FAIL_STATE_DIR="$tmp/install/state" \
  LASTSTACK_FETCH_FAIL_SOFT_MAX=3 \
  "$tmp/install/bin/last-stack-routine-read" demo >/tmp/self-upgrade-fetch3.out 2>/tmp/self-upgrade-fetch3.err; then
  echo "expected error-fetch streak escalate still defer" >&2
  exit 1
fi
grep -q 'LAST_STACK_ROUTINE_ESCALATED self_upgrade_fetch_failed' /tmp/self-upgrade-fetch3.err
grep -q 'streak=3' /tmp/self-upgrade-fetch3.err

mv "$tmp/install/bin/last-stack-self-upgrade.real" "$tmp/install/bin/last-stack-self-upgrade"

# --- routine-read defers on a concurrent self-upgrade lock ---
mkdir "$tmp/install/.self-upgrade.lock"
printf '999999\n' >"$tmp/install/.self-upgrade.lock/pid"
if LASTSTACK_ROUTINE_READ_LOCK_ATTEMPTS=1 LASTSTACK_ROUTINE_READ_LOCK_BACKOFF_S=0 \
  "$tmp/install/bin/last-stack-routine-read" demo >/tmp/self-upgrade-lock.out 2>/tmp/self-upgrade-lock.err; then
  echo "expected held self-upgrade lock to defer routine-read" >&2
  exit 1
fi
grep -q 'LAST_STACK_ROUTINE_DEFERRED self_upgrade_lock' /tmp/self-upgrade-lock.err
grep -q 'result=error-lock' /tmp/self-upgrade-lock.err
if grep -q 'LAST_STACK_ROUTINE_STALE' /tmp/self-upgrade-lock.err; then
  echo "expected held self-upgrade lock to avoid stale failure classification" >&2
  exit 1
fi
rm -rf "$tmp/install/.self-upgrade.lock"

# --- lastgit venue: defaults to lastgit remote over a stale origin mirror ---
# Simulates the read-only GitHub mirror lagging behind the canonical LastGit
# remote: the install is legitimately fast-forward-ahead of the stale
# `origin` mirror, which used to misreport `error-diverged` before
# default_remote() learned to prefer `lastgit` for lastgit-venue repos.
lgtmp="$(mktemp -d)"
lgcleanup() {
  rm -rf "$lgtmp"
}
trap lgcleanup EXIT

git -c init.defaultBranch=main init --bare "$lgtmp/origin-mirror.git" >/dev/null
git -c init.defaultBranch=main init --bare "$lgtmp/lastgit.git" >/dev/null
git clone "$lgtmp/lastgit.git" "$lgtmp/seed" >/dev/null 2>&1
git -C "$lgtmp/seed" config user.email test@example.com
git -C "$lgtmp/seed" config user.name Test
printf 'initial\n' >"$lgtmp/seed/README.md"
git -C "$lgtmp/seed" add .
git -C "$lgtmp/seed" commit -m initial >/dev/null
git -C "$lgtmp/seed" push origin HEAD:main >/dev/null 2>&1
# origin mirror only gets the first commit (stale).
git -C "$lgtmp/seed" push "$lgtmp/origin-mirror.git" HEAD:main >/dev/null 2>&1

# Install clones from the (stale) origin mirror — matching real repos, where
# `origin` is the branch's tracked upstream from the original clone, and a
# separate `lastgit` remote is added later WITHOUT ever renaming/re-tracking
# origin. (A prior version of this test used `remote rename origin lastgit`,
# which quietly re-points the branch's tracking config at `lastgit` too and so
# never exercises the real-world mismatch below.)
git clone "$lgtmp/origin-mirror.git" "$lgtmp/install" >/dev/null 2>&1
mkdir -p "$lgtmp/install/bin" "$lgtmp/install/.last-stack"
cp "$ROOT/bin/last-stack-self-upgrade" "$lgtmp/install/bin/last-stack-self-upgrade"
chmod +x "$lgtmp/install/bin/last-stack-self-upgrade"
cp "$ROOT/VERSION" "$lgtmp/install/VERSION"
printf 'lastgit\n' >"$lgtmp/install/.last-stack/pr-venue"
git -C "$lgtmp/install" remote add lastgit "$lgtmp/lastgit.git"

# Advance lastgit (canonical) further than the stale origin mirror.
printf 'second\n' >>"$lgtmp/seed/README.md"
git -C "$lgtmp/seed" commit -am second >/dev/null
git -C "$lgtmp/seed" push origin HEAD:main >/dev/null 2>&1

# Real (non-check-only) upgrade through the lastgit venue remote: the local
# branch's tracked upstream is `origin`, not `lastgit`, so a bare
# `git pull --ff-only lastgit` fails with "did not specify a branch" unless
# the branch is passed explicitly. This reproduces the 2026-07-20 kanban-pickup
# stall where every scheduled routine saw the install as permanently stale
# because self-upgrade could never actually complete the pull.
old_head="$(git -C "$lgtmp/install" rev-parse --short=12 HEAD)"
out="$("$lgtmp/install/bin/last-stack-self-upgrade" --reason=test)"
case "$out" in
  *"result=upgraded"*"local_head=$old_head"*) ;;
  *)
    printf 'expected real upgrade via lastgit venue remote (tracked-remote mismatch), got:\n%s\n' "$out" >&2
    exit 1
    ;;
esac
grep -q 'second' "$lgtmp/install/README.md"

# Explicit origin comparison reproduces the old bug: install is ahead of the
# stale mirror, which `merge-base --is-ancestor` reports as not-an-ancestor.
out="$(LASTSTACK_REMOTE_REPO=origin "$lgtmp/install/bin/last-stack-self-upgrade" --check-only --reason=test || true)"
case "$out" in
  *"result=error-diverged"*) ;;
  *)
    printf 'expected error-diverged against stale origin mirror, got:\n%s\n' "$out" >&2
    exit 1
    ;;
esac

# Default (no LASTSTACK_REMOTE_REPO) must prefer lastgit and see up-to-date.
out="$("$lgtmp/install/bin/last-stack-self-upgrade" --check-only --reason=test)"
case "$out" in
  *"result=up-to-date"*) ;;
  *)
    printf 'expected default remote to prefer lastgit and report up-to-date, got:\n%s\n' "$out" >&2
    exit 1
    ;;
esac

# Without the lastgit pr-venue opt-in, default must stay origin (unchanged
# behavior) even when a lastgit remote exists.
rm -f "$lgtmp/install/.last-stack/pr-venue"
out="$("$lgtmp/install/bin/last-stack-self-upgrade" --check-only --reason=test || true)"
case "$out" in
  *"result=error-diverged"*) ;;
  *)
    printf 'expected default to stay origin without pr-venue opt-in, got:\n%s\n' "$out" >&2
    exit 1
    ;;
esac

lgcleanup
trap cleanup EXIT

echo "ok"
