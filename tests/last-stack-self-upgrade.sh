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

echo "ok"
