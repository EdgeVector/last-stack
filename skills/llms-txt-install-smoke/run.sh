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

# Bounded-command helpers (run_bounded / fail_steps_summary). Sourced after PATH
# so the timeout-binary probe sees the same PATH the smoke itself uses.
SMOKE_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib-bounded.sh
. "$SMOKE_SKILL_DIR/lib-bounded.sh"

# Per-call bound for the quick-try block. One hung brain/search call must fail
# that step, not consume the whole routine budget.
QUICK_TRY_TIMEOUT="${QUICK_TRY_TIMEOUT:-60}"
# Per-call bound for the app init/list calls. `brain init` bootstraps 25 node
# schemas and is where the 2026-08-29 run stalled; it is slower than a quick-try
# verb but must still be a step that can fail, not a hang.
APP_INIT_TIMEOUT="${APP_INIT_TIMEOUT:-120}"
# Per-call bound for the heavy install steps (clone, setup, install-apps).
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-240}"
# The one global budget. 540s leaves a minute of footer/cleanup margin under the
# agent Bash tool's hard 600s foreground cap, which is what killed the run that
# filed this: no VERDICT line, nothing to report, no way to tell a hang from a
# slow host. Set 0 to disable for interactive debugging.
SMOKE_TOTAL_BUDGET_SECS="${SMOKE_TOTAL_BUDGET_SECS:-540}"
smoke_deadline_init "$SMOKE_TOTAL_BUDGET_SECS"

FAILS=()
PASS=()
# Every step marker and result goes to fd 4 (the REAL stderr) as well as the
# log. `exec >>"$LOG" 2>&1` below sends ordinary output to a file inside the
# disposable sandbox, so a killed run used to leave the caller nothing at all —
# the 2026-08-29 recurrence had to be reconstructed from a leftover sandbox that
# only survived because the EXIT trap never ran. Live breadcrumbs mean the tool
# result itself names the last step reached and how long the run had been going.
live() { echo "$*" >&4; echo "$*"; }
step() { live "[$(smoke_elapsed)s] >>> $1"; }
note_pass() { PASS+=("$1"); live "[$(smoke_elapsed)s]   OK  $1"; }
note_fail() { FAILS+=("$1"); live "[$(smoke_elapsed)s]   FAIL $1"; }

# bounded_step <fail-label> <bound> <command...>
# Run a step under the smaller of its own bound and the global budget, then
# record pass/fail. A fired bound is reported as an explicit timeout so a hang
# never reads as an ordinary nonzero exit.
bounded_step() {
  local label="$1" bound="$2"
  shift 2
  local effective rc=0
  if smoke_deadline_exceeded; then
    note_fail "$label budget-exhausted (global ${SMOKE_TOTAL_BUDGET_SECS}s spent)"
    return 124
  fi
  effective="$(smoke_bounded_remaining "$bound")"
  set +e
  run_bounded "$effective" "$@"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    note_pass "$label"
  elif [ "$rc" -eq 124 ]; then
    note_fail "$label timeout=${effective}s"
  else
    note_fail "$label exit=$rc"
  fi
  return "$rc"
}

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
# Force sandbox routines registry — never inherit host ROUTINES_HOME, which would
# rewrite the live ~/.routines/registry with /tmp/llms-txt-install-smoke paths.
export ROUTINES_HOME="$HOME/.routines"
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
DAEMON_PID=""
cleanup() {
  local exit_rc=$?
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  if [ "$exit_rc" -ne 0 ] && [ -n "${LLMS_TXT_SMOKE_FAILURE_LOG:-}" ]; then
    if preserve_failure_log "$LOG" "$LLMS_TXT_SMOKE_FAILURE_LOG"; then
      echo "failure log preserved: $LLMS_TXT_SMOKE_FAILURE_LOG" >&4
    else
      echo "warning: could not preserve failure log at $LLMS_TXT_SMOKE_FAILURE_LOG" >&4
    fi
  fi
  if [ "$KEEP" -eq 0 ]; then
    rm -rf "$FRESH_ROOT"
  else
    echo "sandbox kept at $FRESH_ROOT" >&2
  fi
  return "$exit_rc"
}
trap cleanup EXIT

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
  step "installing bun (sandbox-aware)"
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
step "clone last-stack"
echo "source: $LAST_STACK_INSTALL_SOURCE"
bounded_step "clone:last-stack" "$INSTALL_TIMEOUT" \
  git clone --depth 1 "$LAST_STACK_INSTALL_SOURCE" "$HOME/.last-stack" || true

step "setup"
if [ -x "$HOME/.last-stack/setup" ]; then
  bounded_step "setup" "$INSTALL_TIMEOUT" "$HOME/.last-stack/setup" || true
else
  note_fail "setup missing"
fi

step "install-apps"
if [ -x "$HOME/.last-stack/bin/last-stack-install-apps" ]; then
  # Apps clone under sandbox HOME. Use --no-brew: this smoke already requires a
  # system lastdbd on PATH, and brew install under a non-login HOME must never
  # rewrite the machine-wide launchd service plist (Dir.home freeze).
  bounded_step "install-apps" "$INSTALL_TIMEOUT" \
    "$HOME/.last-stack/bin/last-stack-install-apps" --no-brew || true
else
  note_fail "install-apps missing"
fi

export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
# Prefer sandbox-linked brain if present
if [ -x "$HOME/lastdb-apps/brain/bin/brain" ]; then
  export PATH="$HOME/lastdb-apps/brain/bin:$PATH"
fi

for cli in brain kanban situations search; do
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
step "inspect brew service home (read-only; no brew services start)"
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
step "start isolated lastdbd"
mkdir -p "$LASTDB_HOME"
lastdbd --data-dir "$LASTDB_HOME" >"$FRESH_ROOT/lastdbd.out" 2>"$FRESH_ROOT/lastdbd.err" &
DAEMON_PID=$!

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
step "app inits"
if command -v brain >/dev/null 2>&1; then
  # This is where the 2026-08-29 run died: `brain init` declares 25 node-owned
  # schemas and had no bound at all, so a slow or wedged bootstrap consumed the
  # whole foreground cap and the run produced no verdict.
  bounded_step "brain:init" "$APP_INIT_TIMEOUT" brain init --grant-consent || true
  if [ -f "$HOME/.brain/config.json" ]; then
    if grep -q ':9001' "$HOME/.brain/config.json"; then
      note_fail "brain:config still contains :9001 (retired TCP)"
    else
      note_pass "brain:config has no :9001"
    fi
  fi
fi

if command -v kanban >/dev/null 2>&1; then
  bounded_step "kanban:init" "$APP_INIT_TIMEOUT" kanban init || true
  bounded_step "kanban:list" "$APP_INIT_TIMEOUT" \
    sh -c 'kanban list >/tmp/kanban-list.out 2>&1' || true
  if [ -f "$HOME/.kanban/config.json" ] && grep -q ':9001' "$HOME/.kanban/config.json"; then
    note_fail "kanban:config still contains :9001"
  elif [ -f "$HOME/.kanban/config.json" ]; then
    note_pass "kanban:config has no :9001"
  fi
fi

if command -v situations >/dev/null 2>&1; then
  bounded_step "situations:init" "$APP_INIT_TIMEOUT" situations init || true
  bounded_step "situations:list" "$APP_INIT_TIMEOUT" \
    sh -c 'situations list >/tmp/sit-list.out 2>&1' || true
  if [ -f "$HOME/.situations/config.json" ] && grep -q ':9001' "$HOME/.situations/config.json"; then
    note_fail "situations:config still contains :9001"
  elif [ -f "$HOME/.situations/config.json" ]; then
    note_pass "situations:config has no :9001"
  fi
fi

if command -v search >/dev/null 2>&1; then
  set +e
  run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" search init --quiet
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    note_pass "search:init"
  elif [ $rc -eq 124 ]; then
    note_fail "search:init timeout=${QUICK_TRY_TIMEOUT}s"
  else
    note_fail "search:init exit=$rc"
  fi
fi

# --- quick try (llms.txt) ---
if command -v brain >/dev/null 2>&1; then
  set +e
  run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" brain concept new hello --title "Hello" --body "my first note"
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    note_pass "brain:concept-new"
  elif [ $rc -eq 124 ]; then
    note_fail "brain:concept-new timeout=${QUICK_TRY_TIMEOUT}s"
  else
    note_fail "brain:concept-new exit=$rc"
  fi
  set +e
  get_out=$(run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" brain get hello 2>&1)
  rc=$?
  set -e
  if [ $rc -eq 0 ] && echo "$get_out" | grep -qi 'first note\|Hello'; then
    note_pass "brain:get-hello"
  elif [ $rc -eq 124 ]; then
    note_fail "brain:get-hello timeout=${QUICK_TRY_TIMEOUT}s"
  else
    note_fail "brain:get-hello"
  fi
  # Prefer concrete term; allow search fallback if ask index lags
  set +e
  ask_out=$(run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" brain ask "first note" 2>&1)
  ask_rc=$?
  search_out=$(run_bounded "$(smoke_bounded_remaining "$QUICK_TRY_TIMEOUT")" brain search "first note" 2>&1)
  search_rc=$?
  set -e
  if echo "$ask_out$search_out" | grep -qi 'hello\|first note'; then
    note_pass "brain:ask-or-search"
  elif [ $ask_rc -eq 124 ] || [ $search_rc -eq 124 ]; then
    note_fail "brain:ask-or-search timeout=${QUICK_TRY_TIMEOUT}s (ask_rc=$ask_rc search_rc=$search_rc)"
  else
    echo "--- brain ask output (exit=$ask_rc) ---"
    printf '%s\n' "$ask_out"
    echo "--- brain search output (exit=$search_rc) ---"
    printf '%s\n' "$search_out"
    note_fail "brain:ask-or-search (ask_rc=$ask_rc search_rc=$search_rc)"
  fi
fi

echo "=========================================="
echo "PASS (${#PASS[@]}): ${PASS[*]:-none}"
echo "FAIL (${#FAILS[@]}): ${FAILS[*]:-none}"
echo "log: $LOG"
# The PASS/FAIL footer used to reach the log only, so the routine agent (and
# routine-run.sh, which greps for these lines) saw a bare verdict with no step
# names. Mirror both onto the status stream.
emit_status "PASS (${#PASS[@]})"
emit_status "FAIL (${#FAILS[@]}): ${FAILS[*]:-none}"
emit_status "log: $LOG"
echo "=========================================="

if [ "${#FAILS[@]}" -eq 0 ]; then
  echo "VERDICT: GREEN" >&2
  emit_status "VERDICT: GREEN"
  emit_json '{"verdict":"GREEN","sandbox":"%s","pass":%d}\n' "$FRESH_ROOT" "${#PASS[@]}"
  exit 0
else
  FAIL_STEPS="$(fail_steps_summary "${FAILS[@]}")"
  echo "VERDICT: RED ${FAIL_STEPS}" >&2
  emit_status "VERDICT: RED ${FAIL_STEPS}"
  emit_json '{"verdict":"RED","sandbox":"%s","steps":"%s","fails":%s}\n' "$FRESH_ROOT" "$FAIL_STEPS" "$(printf '%s\n' "${FAILS[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  exit 1
fi
