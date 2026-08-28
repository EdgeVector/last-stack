#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-pipeline-health-gate"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-health-gate-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fake_stack="$tmp/last-stack"
fake_bin="$fake_stack/bin"
state_dir="$tmp/state"
mkdir -p "$fake_bin" "$state_dir"

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
  young) printf '%s\n' '{"stuck":[{"age_min":2,"reason":"missing_ci"}],"unreadable_repos":[],"index_drift":null}' ;;
  old) printf '%s\n' '{"stuck":[{"age_min":12,"reason":"missing_ci"}],"unreadable_repos":[],"index_drift":null}' ;;
  unreadable) printf '%s\n' '{"stuck":[],"unreadable_repos":["repo"],"index_drift":null}' ;;
  malformed) printf '%s\n' 'not-json' ;;
  error) exit 1 ;;
esac
EOF

cat >"$fake_bin/last-stack-forge-api" <<'EOF'
#!/bin/sh
case "${STUB_FORGE_MODE:-quiet}" in
  quiet) printf '%s\n' '[]' ;;
  young) printf '%s\n' '[{"draft":false,"created_at":"1970-01-01T00:15:00Z"}]' ;;
  young-offset) printf '%s\n' '[{"draft":false,"created_at":"1970-01-01T02:15:00.123+02:00"}]' ;;
  old) printf '%s\n' '[{"draft":false,"created_at":"1970-01-01T00:00:00Z"}]' ;;
  old-offset) printf '%s\n' '[{"draft":false,"created_at":"1969-12-31T17:00:00-07:00"}]' ;;
  draft) printf '%s\n' '[{"draft":true,"created_at":"1970-01-01T00:00:00Z"}]' ;;
  malformed) printf '%s\n' '{}' ;;
  error) exit 1 ;;
esac
EOF

cat >"$fake_bin/last-stack-pipeline-deploy-scan" <<'EOF'
#!/bin/sh
case "${STUB_DEPLOY_MODE:-quiet}" in
  quiet) printf '%s\n' '[{"repo":"one","status":"success","blocked":false}]' ;;
  blocked) printf '%s\n' '[{"repo":"one","status":"failure","blocked":true}]' ;;
  unknown) printf '%s\n' '[{"repo":"one","status":"unknown","blocked":false}]' ;;
  empty) printf '%s\n' '[]' ;;
  malformed) printf '%s\n' '{}' ;;
  error) exit 1 ;;
esac
EOF

cat >"$fake_bin/last-stack-brain-append-heartbeat" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$tmp/timeout" "$tmp/lastgit" "$fake_bin"/* "$GATE"

export LAST_STACK_ROOT="$fake_stack"
export LAST_STACK_PIPELINE_GATE_STATE_DIR="$state_dir"
export LAST_STACK_PIPELINE_GATE_TIMEOUT_BIN="$tmp/timeout"
export LAST_STACK_PIPELINE_GATE_LASTGIT_BIN="$tmp/lastgit"
export LAST_STACK_PIPELINE_GATE_FORGE_API_BIN="$fake_bin/last-stack-forge-api"
export LAST_STACK_PIPELINE_GATE_DEPLOY_SCAN_BIN="$fake_bin/last-stack-pipeline-deploy-scan"
LAST_STACK_PIPELINE_GATE_JQ_BIN="$(command -v jq)"
export LAST_STACK_PIPELINE_GATE_JQ_BIN
export LAST_STACK_PIPELINE_GATE_NOW_EPOCH=1000
export LAST_STACK_PIPELINE_GATE_DEEP_MAX_AGE_SEC=3600
export LAST_STACK_PIPELINE_GATE_MIN_AGE_MIN=10

reset_modes() {
  export STUB_LASTGIT_MODE=quiet
  export STUB_FORGE_MODE=quiet
  export STUB_DEPLOY_MODE=quiet
  export STUB_TIMEOUT_MODE=run
  printf '%s\n' 900 >"$state_dir/last-deep-epoch"
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

# No deep-pass stamp forces the first full agent pass.
reset_modes
rm -f "$state_dir/last-deep-epoch"
run_case deep-pulse 10 'reason=deep-pulse-due'

# A complete quiet inventory skips the agent.
reset_modes
run_case quiet 0 'ROUTINE_RESULT outcome=noop'

# The LastGit CLI can return young missing-CI rows despite --min-age-min.
reset_modes
export STUB_LASTGIT_MODE=young
run_case lastgit-young 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export STUB_LASTGIT_MODE=old
run_case lastgit-old 10 'reason=lastgit-stuck-1'

reset_modes
export STUB_LASTGIT_MODE=unreadable
run_case lastgit-unreadable 10 'reason=lastgit-unreadable-1'

reset_modes
export STUB_LASTGIT_MODE=malformed
run_case lastgit-malformed 10 'reason=lastgit-json-invalid'

reset_modes
export STUB_FORGE_MODE=young
run_case forge-young 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export STUB_FORGE_MODE=young-offset
run_case forge-young-offset 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export STUB_FORGE_MODE=old
run_case forge-old 10 'reason=forge-open-2'

reset_modes
export STUB_FORGE_MODE=old-offset
run_case forge-old-offset 10 'reason=forge-open-2'

reset_modes
export STUB_FORGE_MODE=draft
run_case forge-draft 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export STUB_DEPLOY_MODE=blocked
run_case deploy-blocked 10 'reason=deploy-blocked-1'

reset_modes
export STUB_DEPLOY_MODE=unknown
run_case deploy-unknown 10 'reason=deploy-unknown-1'

reset_modes
export STUB_DEPLOY_MODE=empty
run_case deploy-empty 10 'reason=deploy-json-invalid'

reset_modes
export STUB_TIMEOUT_MODE=timeout
run_case timeout 10 'reason=lastgit-read-rc-124'

reset_modes
export LAST_STACK_PIPELINE_GATE_DEPLOY_SCAN_BIN="$tmp/missing"
run_case missing-tool 10 'reason=deploy-scan-missing'

echo "ok last-stack-pipeline-health-gate"
