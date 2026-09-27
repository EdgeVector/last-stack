#!/usr/bin/env bash
# The HEAL node re-execs a harness itself. Tests 1-6 below exercise the
# fallback path (no `routines` on PATH): a direct Situations-gated
# grok/claude order, so it must honour the same harness-outage Situations
# routinesd honours. Before that gate existed, a bare PATH probe always
# chose grok; during the 2026-08-18 grok usage-limit outage grok answered
# 402, printed no HEAL_RESULT line, and every lastdb-canary-release
# execution reached FAILED with the diagnosis "agent produced no HEAL_RESULT
# line" — a true statement naming neither the outage nor the cause.
#
# Tests 7-8 exercise the PRIMARY path: `routines agent-exec` resolves a
# harness from the same fleet-wide provider-order tracker every other
# routine dispatch reads, instead of this node's own hardcoded grok-first
# order — the 2026-09-26 fleet reroute (providerOrder -> codex-first) fixed
# every ordinary dispatch but not this node, because this node picked its
# own harness directly
# (papercut-canary-heal-adapter-dispatches-grok-during-active-harness-outage,
# recurrence 2026-09-27 lastgit-era-3-builder run 39).
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
HEAL="$ROOT/lib/canary-loom/loom-canary-heal.sh"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$HEAL" ] || fail "heal node missing"
bash -n "$HEAL"

# Both shipped copies must stay byte-identical; the collect defect of 2026-08-30
# shipped because one copy was patched and the other was not.
cmp -s "$HEAL" "$ROOT/lib/canary-red/loom-canary-heal.sh" \
  || fail "canary-loom and canary-red copies of loom-canary-heal.sh have drifted"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-heal-fence.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/cwd"

# A poisoned grok: invoking it at all is the regression.
cat > "$tmp/bin/grok" <<'EOF'
#!/usr/bin/env bash
echo "POISONED_GROK_WAS_INVOKED" >&2
exit 0
EOF

cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
echo 'HEAL_RESULT {"heal_status":"noop","repo":"EdgeVector/last-stack","pr_url":"","merge_sha":"","diagnosis":"claude ran"}'
EOF
chmod +x "$tmp/bin/grok" "$tmp/bin/claude"

mk_situations() { # $1 = json body
  cat > "$tmp/bin/situations" <<EOF
#!/usr/bin/env bash
cat <<'JSON'
$1
JSON
EOF
  chmod +x "$tmp/bin/situations"
}

mk_routines() { # $1 = agent-exec JSON body, $2 = exit code (default 0)
  local body="$1" code="${2:-0}"
  cat > "$tmp/bin/routines" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "agent-exec" ]; then
  cat <<'JSON'
$body
JSON
  exit $code
fi
exit 2
EOF
  chmod +x "$tmp/bin/routines"
}

run_heal() {
  env PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      LOOM_LIVE=1 \
      CANARY_RED_CWD="$tmp/cwd" \
      LOOM_INPUT='{"exec_id":"lx-test-1","attempt":1,"max_attempts":3}' \
      bash "$HEAL" 2>&1
}

GROK_FENCED='[{"slug":"harness-outage-grok","status":"active","blocked_actions":["dispatch-grok-agents"]}]'
BOTH_FENCED='[{"slug":"harness-outage-grok","status":"active","blocked_actions":["dispatch-grok-agents"]},
 {"slug":"harness-outage-claude","status":"active","blocked_actions":["dispatch-claude-agents"]}]'
NONE_FENCED='[]'
EXPIRED='[{"slug":"harness-outage-grok","status":"expired","blocked_actions":["dispatch-grok-agents"]}]'

# 1. grok fenced -> claude runs, grok is never invoked.
mk_situations "$GROK_FENCED"
out="$(run_heal)" || fail "heal exited non-zero with grok fenced"
case "$out" in
  *POISONED_GROK_WAS_INVOKED*) fail "dispatched grok while harness-outage-grok is active" ;;
esac
case "$out" in
  *'"heal_status":"noop"'*) : ;;
  *) fail "expected claude's HEAL_RESULT to be adopted; got: $out" ;;
esac

# 2. No outage -> the existing grok-first preference is preserved.
mk_situations "$NONE_FENCED"
out="$(run_heal)" || fail "heal exited non-zero with no outage"
case "$out" in
  *POISONED_GROK_WAS_INVOKED*) : ;;
  *) fail "with no active outage the adapter must still prefer grok; got: $out" ;;
esac

# 3. An expired outage must not fence; only status=active counts.
mk_situations "$EXPIRED"
out="$(run_heal)" || fail "heal exited non-zero with expired outage"
case "$out" in
  *POISONED_GROK_WAS_INVOKED*) : ;;
  *) fail "an expired Situation must not fence a harness; got: $out" ;;
esac

# 4. Every harness fenced -> blocked, and the diagnosis names the outage.
mk_situations "$BOTH_FENCED"
out="$(run_heal)" || fail "heal exited non-zero with every harness fenced"
case "$out" in
  *POISONED_GROK_WAS_INVOKED*) fail "dispatched a fenced harness" ;;
esac
case "$out" in
  *'"heal_status":"blocked"'*) : ;;
  *) fail "expected blocked when every harness is fenced; got: $out" ;;
esac
case "$out" in
  *harness-outage-grok*) : ;;
  *) fail "blocked diagnosis must name the outage slug; got: $out" ;;
esac

# 5. Situations unreadable -> fail OPEN, still heal (the lane is already red).
cat > "$tmp/bin/situations" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 1
EOF
chmod +x "$tmp/bin/situations"
out="$(run_heal)" || fail "heal must not fail when Situations is unreadable"
case "$out" in
  *POISONED_GROK_WAS_INVOKED*) : ;;
  *) fail "unreadable Situations must fail open and keep the normal order; got: $out" ;;
esac

# 6. No HEAL_RESULT line -> the diagnosis carries the agent's own last output,
#    so a 402 is visible in the execution record instead of being paraphrased.
mk_situations "$NONE_FENCED"
cat > "$tmp/bin/grok" <<'EOF'
#!/usr/bin/env bash
echo 'API error (status 402 Payment Required): Grok Build usage balance exhausted' >&2
exit 0
EOF
chmod +x "$tmp/bin/grok"
out="$(run_heal)" || fail "heal exited non-zero on a silent agent"
case "$out" in
  *'402 Payment Required'*) : ;;
  *) fail "diagnosis must carry the agent's last output; got: $out" ;;
esac

# 7. `routines` on PATH and resolving an available harness -> that harness
#    wins over the hardcoded grok-first order, and its model reaches the
#    agent. grok is on PATH and unfenced, so a regression here means the
#    node ignored the fleet routing matrix.
cat > "$tmp/bin/grok" <<'EOF'
#!/usr/bin/env bash
echo "POISONED_GROK_WAS_INVOKED" >&2
exit 0
EOF
chmod +x "$tmp/bin/grok"
cat > "$tmp/bin/codex" <<'EOF'
#!/usr/bin/env bash
stdin="$(cat)"
echo "CODEX_INVOKED argv=$* stdin_bytes=${#stdin}"
EOF
chmod +x "$tmp/bin/codex"
mk_routines '{"harness":"codex","model":"test-model-x","empty":false,"reasons":["selected=codex model=test-model-x"]}' 0
out="$(run_heal)" || fail "heal exited non-zero when the routing matrix resolves codex"
case "$out" in
  *POISONED_GROK_WAS_INVOKED*) fail "dispatched grok even though the routing matrix resolved codex" ;;
esac
case "$out" in
  *CODEX_INVOKED*) : ;;
  *) fail "expected codex to be invoked (routing matrix resolved codex); got: $out" ;;
esac
case "$out" in
  *"-m test-model-x"*) : ;;
  *) fail "expected the routing matrix's resolved model to reach codex; got: $out" ;;
esac
case "$out" in
  *"stdin_bytes=0"*) fail "codex must receive the prompt via stdin, got zero bytes; got: $out" ;;
esac

# 8. Every provider fenced by the routing matrix itself (rc=3, empty route)
#    -> blocked, and the diagnosis carries the matrix's own reasons. Never
#    fall back to a blind grok dispatch just because the matrix said no.
mk_routines '{"harness":null,"empty":true,"reasons":["provider-order=codex,grok,claude,gemini","fenced=codex,grok,claude,gemini by harness-outage-all"]}' 3
out="$(run_heal)" || fail "heal exited non-zero with every provider fenced by the routing matrix"
case "$out" in
  *POISONED_GROK_WAS_INVOKED*) fail "dispatched grok while the routing matrix reported every provider fenced" ;;
esac
case "$out" in
  *'"heal_status":"blocked"'*) : ;;
  *) fail "expected blocked when the routing matrix reports an empty route; got: $out" ;;
esac
case "$out" in
  *"fleet routing matrix"*harness-outage-all*) : ;;
  *) fail "blocked diagnosis must carry the routing matrix's own reasons; got: $out" ;;
esac
rm -f "$tmp/bin/routines"

printf 'PASS %s\n' "$(basename "$0")"
