#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

stubbin="$tmp/bin"
mkdir -p "$stubbin"

cat >"$stubbin/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log="${BREW_LOG:?}"
printf '%s\n' "HOME=${HOME:-} brew $*" >>"$log"
case "$1" in
  tap)
    if [ "$#" -eq 1 ]; then
      printf '%s\n' "antoniorodr/memo" "openclaw/tap" "steipete/tap" "yakitrak/yakitrak"
      exit 0
    fi
    exit 0
    ;;
  trust)
    if [ "${2:-}" = "--help" ]; then
      cat <<'HELP'
Usage: brew trust [options] [target ...]
      --tap, --taps                Trust the named tap.
      --formula, --formulae        Trust the named formula.
HELP
      exit 0
    fi
    exit 0
    ;;
  install)
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$stubbin/brew"

cat >"$stubbin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "clone" ]; then
  dest="$3"
  mkdir -p "$dest/.git"
  name="$(basename "$dest")"
  case "$name" in
    brain)
      mkdir -p "$dest/bin"
      printf '#!/bin/sh\nexit 0\n' >"$dest/bin/brain"
      printf '#!/bin/sh\nexit 0\n' >"$dest/bin/brain-mcp"
      chmod +x "$dest/bin/brain" "$dest/bin/brain-mcp"
      ;;
    kanban)
      mkdir -p "$dest/bin"
      printf '#!/bin/sh\nexit 0\n' >"$dest/bin/kanban"
      chmod +x "$dest/bin/kanban"
      ;;
    situations)
      mkdir -p "$dest/bin"
      printf '#!/bin/sh\nexit 0\n' >"$dest/bin/situations"
      chmod +x "$dest/bin/situations"
      ;;
    routines)
      mkdir -p "$dest/bin"
      printf '#!/bin/sh\nexit 0\n' >"$dest/bin/routines"
      chmod +x "$dest/bin/routines"
      ;;
    search)
      mkdir -p "$dest/bin"
      printf '#!/bin/sh\nexit 0\n' >"$dest/bin/search"
      chmod +x "$dest/bin/search"
      ;;
    org|lastsecrets)
      mkdir -p "$dest/src"
      printf '#!/usr/bin/env bun\n' >"$dest/src/cli.ts"
      chmod +x "$dest/src/cli.ts"
      ;;
    lastdb-browser)
      mkdir -p "$dest/bin"
      printf '#!/bin/sh\nexit 0\n' >"$dest/bin/lastdb-browser"
      chmod +x "$dest/bin/lastdb-browser"
      ;;
  esac
  printf '{}\n' >"$dest/package.json"
  exit 0
fi
echo "unexpected git command: $*" >&2
exit 1
EOF
chmod +x "$stubbin/git"

cat >"$stubbin/bun" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${BUN_LOG:-/dev/null}"
# BUN_FAIL_TIMES: fail the first N `bun install` invocations, the way a cold
# cache in the smoke's throwaway HOME fails one tarball fetch.
case "$1" in
  install)
    if [ -n "${BUN_FAIL_TIMES:-}" ] && [ -n "${BUN_FAIL_COUNT_FILE:-}" ]; then
      n="$(cat "$BUN_FAIL_COUNT_FILE" 2>/dev/null)"
      [ -n "$n" ] || n=0
      if [ "$n" -lt "$BUN_FAIL_TIMES" ]; then
        printf '%s\n' "$((n + 1))" >"$BUN_FAIL_COUNT_FILE"
        echo 'error: Fail extracting tarball for "protobufjs"' >&2
        exit 1
      fi
    fi
    ;;
esac
exit 0
EOF
chmod +x "$stubbin/bun"

cat >"$stubbin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# npm 11.19.1 `npm --prefix <dir> ci` fails on the lastdb-browser lockfile
# (2026-09-24 canary smoke RED). The installer must cd into the package.
if [ "${1:-}" = "--prefix" ]; then
  echo "npm stub: --prefix is not allowed; run npm inside the package" >&2
  exit 1
fi
test -f package.json || { echo "npm stub: no package.json in $PWD" >&2; exit 1; }
dest="$PWD"
case "$1" in
  ci)
    exit 0
    ;;
  run)
    test "${2:-}" = "build"
    mkdir -p "$dest/dist"
    printf '<!doctype html>\n' >"$dest/dist/index.html"
    ;;
  *)
    echo "unexpected npm command: $*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$stubbin/npm"

HOME="$tmp/home-initial" BREW_LOG="$tmp/brew.log" BUN_LOG="$tmp/bun-initial.log" PATH="$stubbin:/usr/bin:/bin" \
  "$ROOT/bin/last-stack-install-apps" --dir "$tmp/apps" --no-link >/tmp/last-stack-install-apps.out

grep -Eq 'HOME=.+ brew tap( |$)' "$tmp/brew.log"
grep -Eq 'HOME=.+ brew tap edgevector/lastdb' "$tmp/brew.log"
grep -Eq 'HOME=.+ brew trust --tap edgevector/lastdb' "$tmp/brew.log"
grep -Eq 'HOME=.+ brew install edgevector/lastdb/lastdb' "$tmp/brew.log"
# loom and lastseek ship as Homebrew binaries from the same tap.
grep -Eq 'brew install edgevector/lastdb/loom$' "$tmp/brew.log" || { echo "loom was not brew-installed" >&2; exit 1; }
grep -Eq 'brew install edgevector/lastdb/lastseek$' "$tmp/brew.log" || { echo "lastseek was not brew-installed" >&2; exit 1; }
if grep -Eq 'brew trust .*antoniorodr|brew trust .*openclaw|brew trust .*steipete|brew trust .*yakitrak' "$tmp/brew.log"; then
  echo "trusted an unrelated tap" >&2
  exit 1
fi

# When process HOME is a sandbox, brew install must run under the login home so
# the formula service plist never freezes a /tmp/... path.
sandbox_home="$tmp/sandbox-home"
mkdir -p "$sandbox_home"
: >"$tmp/brew-sandbox.log"
HOME="$sandbox_home" BREW_LOG="$tmp/brew-sandbox.log" PATH="$stubbin:/usr/bin:/bin" \
  "$ROOT/bin/last-stack-install-apps" --dir "$tmp/apps-sandbox" --no-link >/tmp/last-stack-install-apps-sandbox.out
login="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
login="${login:-$(eval echo "~$(id -un)")}"
if ! grep -Fq "HOME=$login brew install edgevector/lastdb/lastdb" "$tmp/brew-sandbox.log"; then
  echo "expected brew install under login HOME=$login; got:" >&2
  cat "$tmp/brew-sandbox.log" >&2
  exit 1
fi
if grep -Fq "HOME=$sandbox_home brew install" "$tmp/brew-sandbox.log"; then
  echo "brew install ran under sandbox HOME (would poison launchd plist)" >&2
  exit 1
fi

HOME="$tmp/home" BREW_LOG="$tmp/brew-link.log" BUN_LOG="$tmp/bun.log" PATH="$stubbin:/usr/bin:/bin" \
  "$ROOT/bin/last-stack-install-apps" --dir "$tmp/apps-link" --no-brew >/tmp/last-stack-install-apps-link.out

test "$(readlink "$tmp/home/.local/bin/brain")" = "$tmp/apps-link/brain/bin/brain"
test "$(readlink "$tmp/home/.local/bin/brain-mcp")" = "$tmp/apps-link/brain/bin/brain-mcp"
test "$(readlink "$tmp/home/.local/bin/situations")" = "$tmp/apps-link/situations/bin/situations"
test "$(readlink "$tmp/home/.local/bin/routines")" = "$tmp/apps-link/routines/bin/routines"
test "$(readlink "$tmp/home/.local/bin/lastdb-browser")" = "$tmp/apps-link/lastdb-browser/bin/lastdb-browser"
test -f "$tmp/apps-link/lastdb-browser/dist/index.html"
grep -Fq "exec bun \"$tmp/apps-link/org/src/cli.ts\" \"\$@\"" "$tmp/home/.local/bin/org"
grep -Fq "exec bun \"$tmp/apps-link/lastsecrets/src/cli.ts\" \"\$@\"" "$tmp/home/.local/bin/lastsecrets"
if grep -Fq 'bun link' /tmp/last-stack-install-apps-link.out; then
  echo "installer used bun link for CLI wiring" >&2
  exit 1
fi
grep -Fq -- "--cache-dir $tmp/home/.cache/bun" "$tmp/bun.log"

# A transient dependency fetch must not fail a release proof. This step runs
# inside the llms-txt install smoke, and that smoke's GREEN verdict is what
# writes the app registry `next` rows — so one failed tarball download used to
# cost the whole fleet a delivery cycle (measured 2026-09-26: RED on
# `Fail extracting tarball for "protobufjs"`, identical sha clean on retry).
retry_home="$tmp/home-retry"
rm -rf "$retry_home" "$tmp/apps-retry"
printf '0\n' >"$tmp/bun-fail-count"
HOME="$retry_home" BREW_LOG="$tmp/brew-retry.log" BUN_LOG="$tmp/bun-retry.log" \
  BUN_FAIL_TIMES=2 BUN_FAIL_COUNT_FILE="$tmp/bun-fail-count" \
  LAST_STACK_BUN_INSTALL_ATTEMPTS=3 LAST_STACK_BUN_INSTALL_SLEEP=0 \
  PATH="$stubbin:/usr/bin:/bin" \
  "$ROOT/bin/last-stack-install-apps" --dir "$tmp/apps-retry" --no-brew --no-link \
  >"$tmp/retry.out" 2>&1 || {
    echo "install-apps did not retry a transient bun install failure" >&2
    tail -20 "$tmp/retry.out" >&2
    exit 1
  }
grep -Fq "retrying in" "$tmp/retry.out" || {
  echo "no retry was reported for a failing bun install" >&2
  tail -20 "$tmp/retry.out" >&2
  exit 1
}
test "$(grep -c '^install ' "$tmp/bun-retry.log")" -ge 3 || {
  echo "bun install was not attempted 3 times: $(cat "$tmp/bun-retry.log")" >&2
  exit 1
}

# And a dependency install that fails every time must still FAIL. A retry that
# swallows a real breakage is worse than no retry: the smoke would go GREEN and
# publish a registry row for an app that cannot install.
rm -rf "$tmp/home-retry-fail" "$tmp/apps-retry-fail"
printf '0\n' >"$tmp/bun-fail-count-2"
if HOME="$tmp/home-retry-fail" BREW_LOG="$tmp/brew-rf.log" BUN_LOG="$tmp/bun-rf.log" \
  BUN_FAIL_TIMES=99 BUN_FAIL_COUNT_FILE="$tmp/bun-fail-count-2" \
  LAST_STACK_BUN_INSTALL_ATTEMPTS=2 LAST_STACK_BUN_INSTALL_SLEEP=0 \
  PATH="$stubbin:/usr/bin:/bin" \
  "$ROOT/bin/last-stack-install-apps" --dir "$tmp/apps-retry-fail" --no-brew --no-link \
  >"$tmp/retry-fail.out" 2>&1; then
  echo "a permanently failing bun install was reported as a success" >&2
  exit 1
fi
grep -Fq "giving up" "$tmp/retry-fail.out" || {
  echo "the exhausted-retry path did not say so" >&2
  tail -20 "$tmp/retry-fail.out" >&2
  exit 1
}

echo "ok"
