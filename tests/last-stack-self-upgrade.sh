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

# --- skip flag still fails closed ---
printf 'third fix\n' >>"$tmp/seed/README.md"
git -C "$tmp/seed" commit -am "third fix" >/dev/null
git -C "$tmp/seed" push origin HEAD:main >/dev/null 2>&1
if LASTSTACK_SELF_UPGRADE_SKIP=1 "$tmp/install/bin/last-stack-routine-read" demo >/dev/null 2>/tmp/self-upgrade-skip.err; then
  echo "expected SKIP self-upgrade to keep routine-read stale" >&2
  exit 1
fi
grep -q 'LAST_STACK_ROUTINE_STALE' /tmp/self-upgrade-skip.err

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

git clone "$lgtmp/lastgit.git" "$lgtmp/install" >/dev/null 2>&1
mkdir -p "$lgtmp/install/bin" "$lgtmp/install/.last-stack"
cp "$ROOT/bin/last-stack-self-upgrade" "$lgtmp/install/bin/last-stack-self-upgrade"
chmod +x "$lgtmp/install/bin/last-stack-self-upgrade"
cp "$ROOT/VERSION" "$lgtmp/install/VERSION"
printf 'lastgit\n' >"$lgtmp/install/.last-stack/pr-venue"
git -C "$lgtmp/install" remote rename origin lastgit
git -C "$lgtmp/install" remote add origin "$lgtmp/origin-mirror.git"

# Advance lastgit (canonical) further; install fast-forwards to it and is now
# strictly ahead of the stale origin mirror.
printf 'second\n' >>"$lgtmp/seed/README.md"
git -C "$lgtmp/seed" commit -am second >/dev/null
git -C "$lgtmp/seed" push origin HEAD:main >/dev/null 2>&1
git -C "$lgtmp/install" pull --ff-only lastgit main >/dev/null 2>&1

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
