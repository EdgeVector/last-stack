#!/usr/bin/env bash
# Isolated dogfood of https://thelastdb.com/llms.txt first-run install.
# Never touches the primary LastDB (~/.lastdb) or brew services.
set -euo pipefail

KEEP=0
JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: run.sh [--keep] [--json]

Runs an isolated first-time install smoke based on thelastdb.com/llms.txt.
Creates a temporary HOME, clones last-stack, installs apps, boots lastdbd
against an isolated LASTDB_HOME, runs brain/kanban/situations init + quick try.

  --keep   leave the sandbox directory for inspection
  --json   print a one-line JSON summary to stdout (verdict still on stderr)

Exit 0 = GREEN, 1 = RED.
EOF
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Real user home for brew/lastdbd binaries only — never for data.
REAL_HOME="${REAL_HOME:-$(eval echo "~$(id -un)")}"
export PATH="/opt/homebrew/bin:/usr/local/bin:${REAL_HOME}/.bun/bin:${REAL_HOME}/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

FAILS=()
PASS=()
note_pass() { PASS+=("$1"); echo "  OK  $1" >&2; }
note_fail() { FAILS+=("$1"); echo "  FAIL $1" >&2; }

require_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    note_pass "prereq:$1"
  else
    note_fail "prereq:$1 missing"
  fi
}

FRESH_ROOT="$(mktemp -d /tmp/llms-txt-install-smoke.XXXXXX)"
export FRESH_ROOT
export HOME="$FRESH_ROOT/home"
mkdir -p "$HOME"
export LASTDB_HOME="$HOME/.lastdb"
unset FOLDDB_HOME || true

# Host-only observability injectors (routinesd / agent harness) must not reach
# the isolated lastdbd. Brand-new users following thelastdb.com/llms.txt do not
# carry OBS_SENTRY_* or SENTRY_* — if we inherit them, the canary is a false
# RED (e.g. lastdbd panics on lastsecrets:// OBS_SENTRY_DSN locators) even when
# the public first-run path is fine. Strip known host injectors only; keep
# PATH so prereq `command -v lastdbd` still finds the real host binary.
unset OBS_SENTRY_DSN OBS_SENTRY_ENVIRONMENT OBS_SENTRY_RELEASE \
  OBS_SENTRY_TRACES_SAMPLE_RATE OBS_SENTRY_PROFILES_SAMPLE_RATE \
  SENTRY_DSN SENTRY_ENVIRONMENT SENTRY_RELEASE SENTRY_TRACES_SAMPLE_RATE \
  SENTRY_PROFILES_SAMPLE_RATE 2>/dev/null || true
# Whitelist-safe sweep: drop any remaining OBS_SENTRY_* / SENTRY_* keys.
while IFS= read -r _obs_key; do
  [ -n "$_obs_key" ] || continue
  unset "$_obs_key" 2>/dev/null || true
done <<EOF
$(env | awk -F= '/^(OBS_SENTRY_|SENTRY_)/ { print $1 }')
EOF
unset _obs_key || true

LOG="$FRESH_ROOT/run.log"
exec 3>&1 4>&2
exec >>"$LOG" 2>&1
emit_json() {
  if [ "$JSON" -eq 1 ]; then
    printf "$@" >&3
  fi
}
emit_status() {
  echo "$*" >&4
}

echo "=========================================="
echo "llms-txt install smoke (isolated)"
echo "sandbox: $FRESH_ROOT"
echo "HOME=$HOME LASTDB_HOME=$LASTDB_HOME"
echo "=========================================="

require_cmd brew
require_cmd git
require_cmd curl
require_cmd lastdbd

# Bun: install into sandbox if missing; allow pre-existing system bun
if ! command -v bun >/dev/null 2>&1; then
  echo ">>> installing bun (sandbox-aware)"
  curl -fsSL https://bun.sh/install | bash || true
fi
export PATH="$HOME/.bun/bin:${REAL_HOME}/.bun/bin:$HOME/.local/bin:$PATH"
if command -v bun >/dev/null 2>&1; then
  note_pass "prereq:bun ($(bun --version))"
else
  note_fail "prereq:bun missing"
fi

if [ "${#FAILS[@]}" -gt 0 ] && printf '%s\n' "${FAILS[@]}" | grep -q '^prereq:'; then
  echo "VERDICT: RED (missing prereqs)" >&2
  emit_status "VERDICT: RED (missing prereqs)"
  emit_json '{"verdict":"RED","reason":"prereqs","sandbox":"%s"}\n' "$FRESH_ROOT"
  exit 1
fi

# --- last-stack ---
LAST_STACK_INSTALL_SOURCE="${LAST_STACK_INSTALL_SOURCE:-https://github.com/EdgeVector/last-stack.git}"
echo ">>> clone last-stack"
echo "source: $LAST_STACK_INSTALL_SOURCE"
if git clone --depth 1 "$LAST_STACK_INSTALL_SOURCE" "$HOME/.last-stack"; then
  note_pass "clone:last-stack"
else
  note_fail "clone:last-stack"
fi

if [ -x "$HOME/.last-stack/setup" ]; then
  if "$HOME/.last-stack/setup"; then
    note_pass "setup"
  else
    note_fail "setup (exit $?)"
  fi
else
  note_fail "setup missing"
fi

if [ -x "$HOME/.last-stack/bin/last-stack-install-apps" ]; then
  # Apps clone under sandbox HOME. Use --no-brew: this smoke already requires a
  # system lastdbd on PATH, and brew install under a non-login HOME must never
  # rewrite the machine-wide launchd service plist (Dir.home freeze).
  set +e
  "$HOME/.last-stack/bin/last-stack-install-apps" --no-brew
  APPS_RC=$?
  set -e
  if [ "$APPS_RC" -eq 0 ]; then
    note_pass "install-apps"
  else
    note_fail "install-apps exit=$APPS_RC"
  fi
else
  note_fail "install-apps missing"
fi

export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
# Prefer sandbox-linked brain if present
if [ -x "$HOME/lastdb-apps/brain/bin/brain" ]; then
  export PATH="$HOME/lastdb-apps/brain/bin:$PATH"
fi

for cli in brain kanban situations; do
  if command -v "$cli" >/dev/null 2>&1; then
    note_pass "cli:$cli=$(command -v $cli)"
  else
    note_fail "cli:$cli not on PATH"
  fi
done

# --- brew service home (website path uses `brew services start lastdb`) ---
# Never start/stop brew services here — only inspect the installed service
# definition so a poisoned /tmp HOME cannot go GREEN while the isolated
# daemon path still works.
echo ">>> inspect brew service home (read-only; no brew services start)"
assert_brew_service_home() {
  local brew_prefix plist prog env_home env_lastdb login
  login="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)"
  login="${login:-$REAL_HOME}"
  brew_prefix="$(brew --prefix edgevector/lastdb/lastdb 2>/dev/null || brew --prefix lastdb 2>/dev/null || true)"
  if [ -z "$brew_prefix" ] || [ ! -d "$brew_prefix" ]; then
    note_fail "brew-service:formula not installed (website path needs brew install edgevector/lastdb/lastdb)"
    return
  fi
  plist="$brew_prefix/homebrew.mxcl.lastdb.plist"
  if [ ! -f "$plist" ]; then
    note_fail "brew-service:plist missing at $plist"
    return
  fi
  # Reject install-time Dir.home freeze into a temp/sandbox path.
  env_home="$(plutil -extract EnvironmentVariables.HOME raw "$plist" 2>/dev/null || true)"
  env_lastdb="$(plutil -extract EnvironmentVariables.LASTDB_HOME raw "$plist" 2>/dev/null || true)"
  if printf '%s\n' "$env_home" "$env_lastdb" | grep -Eqe '^/tmp/|/var/folders/'; then
    note_fail "brew-service:plist freezes temp HOME/LASTDB_HOME (HOME=${env_home:-unset} LASTDB_HOME=${env_lastdb:-unset})"
    return
  fi
  if [ -n "$env_home" ] && [ "$env_home" != "$login" ]; then
    note_fail "brew-service:plist HOME=$env_home is not login home $login"
    return
  fi
  if [ -n "$env_lastdb" ] && [ "$env_lastdb" != "$login/.lastdb" ]; then
    note_fail "brew-service:plist LASTDB_HOME=$env_lastdb is not $login/.lastdb"
    return
  fi
  prog="$(plutil -extract ProgramArguments.0 raw "$plist" 2>/dev/null || true)"
  if [ -z "$prog" ]; then
    note_fail "brew-service:ProgramArguments empty"
    return
  fi
  # Preferred: runtime wrapper (resolves login HOME at start).
  if [[ "$prog" == *lastdbd-service ]]; then
    if [ -x "$prog" ] || [ -x "$brew_prefix/bin/lastdbd-service" ]; then
      note_pass "brew-service:runtime-home-wrapper ($prog)"
    else
      note_fail "brew-service:lastdbd-service missing executable at $prog"
    fi
    return
  fi
  # Legacy: bare lastdbd with no baked temp HOME is acceptable if LASTDB_HOME is
  # unset (session HOME) or equals login ~/.lastdb.
  if [[ "$prog" == *lastdbd ]]; then
    if [ -z "$env_home" ] && [ -z "$env_lastdb" ]; then
      note_pass "brew-service:legacy-lastdbd no baked HOME (session home at start)"
      return
    fi
    if [ -z "$env_home" ] || [ "$env_home" = "$login" ]; then
      if [ -z "$env_lastdb" ] || [ "$env_lastdb" = "$login/.lastdb" ]; then
        note_pass "brew-service:legacy-lastdbd login home ok"
        return
      fi
    fi
    note_fail "brew-service:legacy-lastdbd unexpected env HOME=${env_home:-unset} LASTDB_HOME=${env_lastdb:-unset}"
    return
  fi
  note_fail "brew-service:unexpected ProgramArguments[0]=$prog"
}
assert_brew_service_home

# --- isolated daemon (NOT brew services) ---
echo ">>> start isolated lastdbd"
mkdir -p "$LASTDB_HOME"
lastdbd --data-dir "$LASTDB_HOME" >"$FRESH_ROOT/lastdbd.out" 2>"$FRESH_ROOT/lastdbd.err" &
DAEMON_PID=$!
cleanup() {
  if kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ "$KEEP" -eq 0 ]; then
    rm -rf "$FRESH_ROOT"
  else
    echo "sandbox kept at $FRESH_ROOT" >&2
  fi
}
trap cleanup EXIT

SOCK="$LASTDB_HOME/data/folddb.sock"
ready=0
for i in $(seq 1 40); do
  if [ -S "$SOCK" ]; then
    ready=1
    note_pass "daemon:socket after ${i}s pid=$DAEMON_PID"
    break
  fi
  sleep 0.5
done
if [ "$ready" -ne 1 ]; then
  note_fail "daemon:socket never appeared"
  echo "--- lastdbd.err ---"; tail -30 "$FRESH_ROOT/lastdbd.err" || true
fi

# health
if [ -S "$SOCK" ]; then
  HEALTH=$(curl -s --unix-socket "$SOCK" http://localhost/health || true)
  if [ "$HEALTH" = '{"status":"ok"}' ]; then
    note_pass "health:$HEALTH"
  else
    note_fail "health: got '$HEALTH'"
  fi
fi

# --- app inits ---
if command -v brain >/dev/null 2>&1; then
  set +e
  brain init --grant-consent
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    note_pass "brain:init"
  else
    note_fail "brain:init exit=$rc"
  fi
  if [ -f "$HOME/.brain/config.json" ]; then
    if grep -q ':9001' "$HOME/.brain/config.json"; then
      note_fail "brain:config still contains :9001 (retired TCP)"
    else
      note_pass "brain:config has no :9001"
    fi
  fi
fi

if command -v kanban >/dev/null 2>&1; then
  set +e
  kanban init
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    note_pass "kanban:init"
  else
    note_fail "kanban:init exit=$rc"
  fi
  set +e
  kanban list >/tmp/kanban-list.out 2>&1
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    note_pass "kanban:list"
  else
    note_fail "kanban:list exit=$rc"
  fi
  if [ -f "$HOME/.kanban/config.json" ] && grep -q ':9001' "$HOME/.kanban/config.json"; then
    note_fail "kanban:config still contains :9001"
  elif [ -f "$HOME/.kanban/config.json" ]; then
    note_pass "kanban:config has no :9001"
  fi
fi

if command -v situations >/dev/null 2>&1; then
  set +e
  situations init
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    note_pass "situations:init"
  else
    note_fail "situations:init exit=$rc"
  fi
  set +e
  situations list >/tmp/sit-list.out 2>&1
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    note_pass "situations:list"
  else
    note_fail "situations:list exit=$rc"
  fi
  if [ -f "$HOME/.situations/config.json" ] && grep -q ':9001' "$HOME/.situations/config.json"; then
    note_fail "situations:config still contains :9001"
  elif [ -f "$HOME/.situations/config.json" ]; then
    note_pass "situations:config has no :9001"
  fi
fi

# --- quick try (llms.txt) ---
if command -v brain >/dev/null 2>&1; then
  set +e
  brain concept new hello --title "Hello" --body "my first note"
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    note_pass "brain:concept-new"
  else
    note_fail "brain:concept-new exit=$rc"
  fi
  set +e
  get_out=$(brain get hello 2>&1)
  rc=$?
  set -e
  if [ $rc -eq 0 ] && echo "$get_out" | grep -qi 'first note\|Hello'; then
    note_pass "brain:get-hello"
  else
    note_fail "brain:get-hello"
  fi
  # Prefer concrete term; allow search fallback if ask index lags
  set +e
  ask_out=$(brain ask "first note" 2>&1)
  ask_rc=$?
  search_out=$(brain search "first note" 2>&1)
  search_rc=$?
  set -e
  if echo "$ask_out$search_out" | grep -qi 'hello\|first note'; then
    note_pass "brain:ask-or-search"
  else
    note_fail "brain:ask-or-search (ask_rc=$ask_rc search_rc=$search_rc)"
  fi
fi

echo "=========================================="
echo "PASS (${#PASS[@]}): ${PASS[*]:-none}"
echo "FAIL (${#FAILS[@]}): ${FAILS[*]:-none}"
echo "log: $LOG"
emit_status "log: $LOG"
echo "=========================================="

if [ "${#FAILS[@]}" -eq 0 ]; then
  echo "VERDICT: GREEN" >&2
  emit_status "VERDICT: GREEN"
  emit_json '{"verdict":"GREEN","sandbox":"%s","pass":%d}\n' "$FRESH_ROOT" "${#PASS[@]}"
  exit 0
else
  echo "VERDICT: RED" >&2
  emit_status "VERDICT: RED"
  emit_json '{"verdict":"RED","sandbox":"%s","fails":%s}\n' "$FRESH_ROOT" "$(printf '%s\n' "${FAILS[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  exit 1
fi
