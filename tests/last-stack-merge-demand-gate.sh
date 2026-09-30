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

# Every EdgeVector repo except lastgit is canonical on GitHub: its open PRs come
# from `gh api`, never the Forge API.
cat >"$fake_bin/gh" <<'EOF'
#!/bin/sh
[ "$1" = api ] || exit 2
case "$2" in
  repos/EdgeVector/*/pulls\?state=open*) ;;
  *) echo "gh stub: unexpected path $2" >&2; exit 2 ;;
esac
case "${STUB_GH_MODE:-quiet}" in
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
cp "$ROOT/config/merge-demand-github-repos" "$fake_stack/config/merge-demand-github-repos"
chmod +x "$tmp/timeout" "$tmp/lastgit" "$fake_bin"/* "$GATE"

export LAST_STACK_ROOT="$fake_stack"
export LAST_STACK_PIPELINE_GATE_TIMEOUT_BIN="$tmp/timeout"
export LAST_STACK_PIPELINE_GATE_LASTGIT_BIN="$tmp/lastgit"
export LAST_STACK_PIPELINE_GATE_FORGE_API_BIN="$fake_bin/last-stack-forge-api"
export LAST_STACK_PIPELINE_GATE_GH_BIN="$fake_bin/gh"
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
  export STUB_GH_MODE=quiet
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
run_case forge-old 10 'reason=forge-open-1'

# fold is read from GitHub even when a Forge list still names it: one old
# GitHub PR is demand, and the Forge API stub (quiet) is not what answered.
reset_modes
export STUB_GH_MODE=old
LAST_STACK_MERGE_DEMAND_GITHUB_REPOS="EdgeVector/fold" run_case github-fold-old 10 'reason=forge-open-1'

reset_modes
export STUB_GH_MODE=error
run_case github-read-error 10 'reason=forge-read-rc-'

reset_modes
export STUB_DEPLOY_MODE=blocked
run_case deploy-blocked 10 'reason=deploy-blocked-1'

# File default: the lastgit repo on Forgejo plus every moved repo on GitHub, one
# old PR each.
reset_modes
unset LAST_STACK_PIPELINE_GATE_FORGE_REPOS
export STUB_FORGE_MODE=old STUB_GH_MODE=old
gh_count="$(grep -cE '^EdgeVector/' "$ROOT/config/merge-demand-github-repos")"
run_case all-repos-forge-and-github 10 "reason=forge-open-$((gh_count + 1))"
export LAST_STACK_PIPELINE_GATE_FORGE_REPOS="EdgeVector/fold,EdgeVector/lastgit"

repos="$(grep -E '^EdgeVector/' "$ROOT/config/merge-demand-forge-repos" | wc -l | tr -d ' ')"
[ "$repos" = "1" ] || { echo "merge-demand-forge-repos must list only lastgit, got $repos" >&2; exit 1; }
grep -qx 'EdgeVector/lastgit' "$ROOT/config/merge-demand-forge-repos" \
  || { echo "merge-demand-forge-repos must list EdgeVector/lastgit" >&2; exit 1; }
# Every repo that moved is on the GitHub list and none of them is on the Forgejo list.
for name in fold last-stack fkanban routines loom brain situations configurations lastsecrets search remote \
    state-machine reconciler lastdb-browser lastseek exemem-infra exemem-workspace schema-infra fold_db_website \
    homebrew-lastdb ops-terminal kanban-factory code-atlas discovery dogfood-graph factory-graph; do
  grep -qx "EdgeVector/$name" "$ROOT/config/merge-demand-github-repos" \
    || { echo "merge-demand-github-repos must list EdgeVector/$name" >&2; exit 1; }
  if grep -qx "EdgeVector/$name" "$ROOT/config/merge-demand-forge-repos"; then
    echo "$name must not be in merge-demand-forge-repos" >&2; exit 1
  fi
done
if grep -qx 'EdgeVector/lastgit' "$ROOT/config/merge-demand-github-repos"; then
  echo "lastgit must stay off the GitHub list (it is the one Forgejo repo)" >&2; exit 1
fi

echo "ok last-stack-merge-demand-gate"
