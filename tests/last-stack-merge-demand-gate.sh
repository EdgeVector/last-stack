#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-merge-demand-gate"
chmod +x "$GATE"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-demand-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fake_stack="$tmp/last-stack"
fake_bin="$fake_stack/bin"
mkdir -p "$fake_bin" "$fake_stack/config"

cat >"$tmp/timeout" <<'EOF'
#!/bin/sh
if [ "${STUB_TIMEOUT_MODE:-}" = timeout ]; then
  exit 124
fi
shift 3
exec "$@"
EOF

cat >"$tmp/lastgit" <<'EOF'
#!/bin/sh
case "${STUB_LASTGIT_MODE:-quiet}" in
  quiet) printf '%s\n' '{"stuck":[],"unreadable_repos":null,"index_drift":null}' ;;
  old) printf '%s\n' '{"stuck":[{"age_min":12,"reason":"missing_ci"}],"unreadable_repos":[],"index_drift":null}' ;;
  ghost) printf '%s\n' '{"stuck":[{"age_min":12,"reason":"cr_not_found"}],"unreadable_repos":[],"index_drift":null}' ;;
  unreadable) printf '%s\n' '{"stuck":[],"unreadable_repos":["repo"],"index_drift":null}' ;;
  malformed) printf '%s\n' 'not-json' ;;
  error) exit 1 ;;
esac
EOF

cat >"$fake_bin/last-stack-forge-api" <<'EOF'
#!/bin/sh
case "${STUB_FORGE_MODE:-quiet}" in
  quiet) printf '%s\n' '[]' ;;
  old) printf '%s\n' '[{"draft":false,"created_at":"1970-01-01T00:00:00Z"}]' ;;
  error) exit 1 ;;
esac
EOF

cat >"$fake_bin/last-stack-pipeline-deploy-scan" <<'EOF'
#!/bin/sh
case "${STUB_DEPLOY_MODE:-quiet}" in
  quiet) printf '%s\n' '[{"repo":"one","status":"success","blocked":false}]' ;;
  blocked) printf '%s\n' '[{"repo":"one","status":"failure","blocked":true}]' ;;
  error) exit 1 ;;
esac
EOF

cat >"$fake_bin/last-stack-brain-append-heartbeat" <<'EOF'
#!/bin/sh
exit 0
EOF

cp "$ROOT/config/merge-demand-forge-repos" "$fake_stack/config/merge-demand-forge-repos"
chmod +x "$tmp/timeout" "$tmp/lastgit" "$fake_bin"/* "$GATE"

export LAST_STACK_ROOT="$fake_stack"
export LAST_STACK_PIPELINE_GATE_TIMEOUT_BIN="$tmp/timeout"
export LAST_STACK_PIPELINE_GATE_LASTGIT_BIN="$tmp/lastgit"
export LAST_STACK_PIPELINE_GATE_FORGE_API_BIN="$fake_bin/last-stack-forge-api"
export LAST_STACK_PIPELINE_GATE_DEPLOY_SCAN_BIN="$fake_bin/last-stack-pipeline-deploy-scan"
LAST_STACK_PIPELINE_GATE_JQ_BIN="$(command -v jq)"
export LAST_STACK_PIPELINE_GATE_JQ_BIN
export LAST_STACK_PIPELINE_GATE_NOW_EPOCH=1000
export LAST_STACK_PIPELINE_GATE_MIN_AGE_MIN=10
export LAST_STACK_PIPELINE_GATE_FORGE_REPOS="EdgeVector/fold,EdgeVector/lastgit"
unset LAST_STACK_LASTGIT_NATIVE_REPOS || true
unset LAST_STACK_MERGE_DEMAND_FORGE_REPOS || true

reset_modes() {
  export STUB_LASTGIT_MODE=quiet
  export STUB_FORGE_MODE=quiet
  export STUB_DEPLOY_MODE=quiet
  export STUB_TIMEOUT_MODE=run
  unset LAST_STACK_LASTGIT_NATIVE_REPOS || true
}

run_case() {
  local name="$1"
  local expected_rc="$2"
  local expected_text="$3"
  set +e
  out="$("$GATE" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "$name: expected rc=$expected_rc, got rc=$rc" >&2
    echo "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -q "$expected_text"; then
    echo "$name: missing $expected_text" >&2
    echo "$out" >&2
    exit 1
  fi
}

reset_modes
run_case quiet-lastgit-disabled 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export STUB_LASTGIT_MODE=old
run_case lastgit-old-disabled 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export STUB_LASTGIT_MODE=unreadable
run_case lastgit-unreadable-disabled 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/fold"
export STUB_LASTGIT_MODE=old
run_case lastgit-old-enabled 10 'reason=lastgit-stuck-1'

reset_modes
export LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/fold"
export STUB_LASTGIT_MODE=ghost
run_case lastgit-ghost 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/fold"
export STUB_LASTGIT_MODE=unreadable
run_case lastgit-unreadable-enabled 10 'reason=lastgit-unreadable-1'

reset_modes
export STUB_FORGE_MODE=old
run_case forge-old 10 'reason=forge-open-2'

reset_modes
export STUB_DEPLOY_MODE=blocked
run_case deploy-blocked 10 'reason=deploy-blocked-1'

# Seven-repo file: one old PR per repo
reset_modes
unset LAST_STACK_PIPELINE_GATE_FORGE_REPOS
export STUB_FORGE_MODE=old
run_case seven-repo-forge 10 'reason=forge-open-7'
export LAST_STACK_PIPELINE_GATE_FORGE_REPOS="EdgeVector/fold,EdgeVector/lastgit"

repos="$(grep -E '^EdgeVector/' "$ROOT/config/merge-demand-forge-repos" | wc -l | tr -d ' ')"
[ "$repos" = "7" ] || { echo "merge-demand-forge-repos must list 7 repos, got $repos" >&2; exit 1; }

echo "ok last-stack-merge-demand-gate"
