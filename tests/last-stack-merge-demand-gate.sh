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
# Every call is logged: after the lastgit repo moved to GitHub the default gate
# must make NO Forge call, so a dead Forgejo cannot fail it open.
echo "$1" >>"${STUB_FORGE_LOG:?}"
case "${STUB_FORGE_MODE:-quiet}" in
  quiet) printf '%s\n' '[]' ;;
  old) printf '%s\n' '[{"draft":false,"created_at":"1970-01-01T00:00:00Z"}]' ;;
  error|dead) exit 1 ;;
esac
EOF

# Every EdgeVector repo except lastgit is canonical on GitHub: its open PRs come
# from `gh api`, never the Forge API.
cat >"$fake_bin/gh" <<'EOF'
#!/bin/sh
[ "$1" = api ] || exit 2
echo "$2" >>"${STUB_GH_LOG:?}"
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
export STUB_FORGE_LOG="$tmp/forge-calls.log" STUB_GH_LOG="$tmp/gh-calls.log"
# Production shape: the Forge list and the GitHub list both come from the shipped
# config files (the fake stack copies them). No env override of either list.
unset LAST_STACK_PIPELINE_GATE_FORGE_REPOS LAST_STACK_MERGE_DEMAND_FORGE_REPOS \
      LAST_STACK_MERGE_DEMAND_GITHUB_REPOS LAST_STACK_LASTGIT_NATIVE_REPOS || true

reset_modes() {
  export STUB_LASTGIT_MODE=quiet
  export STUB_FORGE_MODE=quiet
  export STUB_GH_MODE=quiet
  export STUB_DEPLOY_MODE=quiet
  export STUB_TIMEOUT_MODE=run
  unset LAST_STACK_LASTGIT_NATIVE_REPOS || true
  : >"$STUB_FORGE_LOG"
  : >"$STUB_GH_LOG"
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
run_case lastgit-old-enabled-retired 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/fold"
export STUB_LASTGIT_MODE=ghost
run_case lastgit-ghost 0 'ROUTINE_RESULT outcome=noop'

reset_modes
export LAST_STACK_LASTGIT_NATIVE_REPOS="EdgeVector/fold"
export STUB_LASTGIT_MODE=unreadable
run_case lastgit-unreadable-enabled-retired 0 'ROUTINE_RESULT outcome=noop'

# --- Default shape (2026-10-08): every repo, lastgit included, is read from GitHub
# and the Forge list is empty. A stopped Forgejo must not fail the gate open.
# Before this change the default Forge list named EdgeVector/lastgit, so a dead
# Forgejo printed PROCEED (`forge-read-rc-1`) on every tick and started the
# merge-babysit agent each time.
reset_modes
export STUB_FORGE_MODE=dead
run_case default-forgejo-dead-stays-quiet 0 'ROUTINE_RESULT outcome=noop'
[ ! -s "$STUB_FORGE_LOG" ] || { echo "default gate called the Forge API:" >&2; cat "$STUB_FORGE_LOG" >&2; exit 1; }
grep -q '^repos/EdgeVector/lastgit/pulls' "$STUB_GH_LOG" \
  || { echo "default gate did not read EdgeVector/lastgit from GitHub" >&2; cat "$STUB_GH_LOG" >&2; exit 1; }

# A stale Forge answer for any repo is not demand any more: Forgejo is never asked.
reset_modes
export STUB_FORGE_MODE=old
run_case default-forgejo-old-is-not-read 0 'ROUTINE_RESULT outcome=noop'
[ ! -s "$STUB_FORGE_LOG" ] || { echo "default gate called the Forge API" >&2; exit 1; }

# The forge-api binary is not required either (Forgejo tooling may be removed).
reset_modes
(
  export LAST_STACK_PIPELINE_GATE_FORGE_API_BIN="$tmp/no-such-forge-api"
  run_case default-forge-api-missing-is-fine 0 'ROUTINE_RESULT outcome=noop'
)

# An old open PR in lastgit is demand, read through gh.
reset_modes
export STUB_GH_MODE=old
LAST_STACK_MERGE_DEMAND_GITHUB_REPOS="EdgeVector/lastgit" run_case lastgit-old-pr-github 10 'reason=forge-open-1'
grep -q '^repos/EdgeVector/lastgit/pulls' "$STUB_GH_LOG" \
  || { echo "lastgit PR was not read through gh" >&2; exit 1; }
[ ! -s "$STUB_FORGE_LOG" ] || { echo "lastgit PR read touched the Forge API" >&2; exit 1; }

# A GitHub read that fails still proceeds (a real outage is not quiet).
reset_modes
export STUB_GH_MODE=error
run_case github-read-error 10 'reason=forge-read-rc-'

reset_modes
export STUB_DEPLOY_MODE=blocked
run_case deploy-blocked 10 'reason=deploy-blocked-1'

# File default: every repo on the GitHub list, one old PR each. Forgejo adds none.
reset_modes
export STUB_FORGE_MODE=old STUB_GH_MODE=old
gh_count="$(grep -cE '^EdgeVector/' "$ROOT/config/merge-demand-github-repos")"
run_case all-repos-github 10 "reason=forge-open-${gh_count}"

# Both lists empty is a broken inventory: exit 2, never a quiet skip.
reset_modes
LAST_STACK_MERGE_DEMAND_GITHUB_REPOS="" run_case both-lists-empty 2 'no repos to read'

# --- Explicit Forge override still works (legacy path, not the default) ---------
reset_modes
export STUB_FORGE_MODE=old
LAST_STACK_MERGE_DEMAND_GITHUB_REPOS="" LAST_STACK_MERGE_DEMAND_FORGE_REPOS="EdgeVector/legacy" \
  run_case forge-override-old 10 'reason=forge-open-1'
grep -q '^repos/EdgeVector/legacy/pulls' "$STUB_FORGE_LOG" \
  || { echo "explicit Forge override did not call the Forge API" >&2; exit 1; }

reset_modes
export STUB_FORGE_MODE=error
LAST_STACK_MERGE_DEMAND_GITHUB_REPOS="" LAST_STACK_MERGE_DEMAND_FORGE_REPOS="EdgeVector/legacy" \
  run_case forge-override-read-error 10 'reason=forge-read-rc-'

# The GitHub list wins over a Forge list that names the same repo.
reset_modes
export STUB_GH_MODE=old
LAST_STACK_MERGE_DEMAND_GITHUB_REPOS="EdgeVector/fold" LAST_STACK_MERGE_DEMAND_FORGE_REPOS="EdgeVector/fold" \
  run_case github-list-wins 10 'reason=forge-open-1'
[ ! -s "$STUB_FORGE_LOG" ] || { echo "a GitHub-listed repo was read from Forgejo" >&2; exit 1; }

# --- The shipped config files ----------------------------------------------------
repos="$(grep -cE '^EdgeVector/' "$ROOT/config/merge-demand-forge-repos" || true)"
[ "$repos" = "0" ] || { echo "merge-demand-forge-repos must list no repo (all are on GitHub), got $repos" >&2; exit 1; }
# Every EdgeVector repo is on the GitHub list and none is on the Forgejo list.
for name in fold last-stack fkanban routines loom brain situations configurations lastsecrets search remote \
    state-machine reconciler lastdb-browser lastseek exemem-infra exemem-workspace schema-infra fold_db_website \
    homebrew-lastdb ops-terminal kanban-factory code-atlas discovery dogfood-graph factory-graph lastgit; do
  grep -qx "EdgeVector/$name" "$ROOT/config/merge-demand-github-repos" \
    || { echo "merge-demand-github-repos must list EdgeVector/$name" >&2; exit 1; }
  if grep -qx "EdgeVector/$name" "$ROOT/config/merge-demand-forge-repos"; then
    echo "$name must not be in merge-demand-forge-repos" >&2; exit 1
  fi
done

echo "ok last-stack-merge-demand-gate"
