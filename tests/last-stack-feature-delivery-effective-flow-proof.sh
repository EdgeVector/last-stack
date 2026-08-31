#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-feature-delivery-effective-flow-proof"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/feature-delivery-proof-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

chmod +x "$BIN" "$ROOT/harness/north-star/feature-delivery-effective-flow/run.sh"
python3 -m py_compile "$BIN"
bash -n "$ROOT/harness/north-star/feature-delivery-effective-flow/run.sh"

python3 - "$BIN" "$TMP/pass.json" <<'PY'
import json
import runpy
import sys

module = runpy.run_path(sys.argv[1])
fixes = module["FIXES"]
stamp = "2026-08-31T20:00:00Z"
components = {}
for repo, repo_fixes in fixes.items():
    head = repo_fixes[-1]["source_commit"]
    components[repo] = {
        "installed_head": head,
        "fixes": [
            {**fix, "installed_head": head, "present": True}
            for fix in repo_fixes
        ],
    }
probes = {}
for name in (
    "card_truth",
    "board_write",
    "flow_ledger",
    "admission",
    "satisfaction",
    "closeout",
    "provider_fallback",
):
    probes[name] = {
        "name": name,
        "status": "pass",
        "started_at": stamp,
        "finished_at": "2026-08-31T20:00:01Z",
        "detail": "fixture passed",
    }
sample = {
    "process_start_ts": 1000,
    "sampled_at": 1010,
    "warm_resident_bytes": 200,
    "warm_budget_bytes": 300,
    "rss_bytes": 400,
    "memory_limit_bytes": 500,
    "runtime_degraded": False,
}
snapshot = {
    "captured_at": stamp,
    "components": components,
    "probes": probes,
    "lastdb": {
        "build": "fixed-fixture",
        "fixed_build": True,
        "required_seconds": 86400,
        "samples": [sample, {**sample, "sampled_at": 87410, "warm_resident_bytes": 250}],
    },
}
with open(sys.argv[2], "w") as stream:
    json.dump(snapshot, stream)
PY

"$BIN" --live --fixture "$TMP/pass.json" --report "$TMP/pass.md" >/dev/null
[ "$(head -n 1 "$TMP/pass.md")" = PASS ] || fail "a complete fixture must write PASS"
for commit in \
  ec51f37a1502fd8cf0ad21e10b293ffca0ae9a7d \
  b3868f5c0bdb7a14d41a391432ac51fbc3a75528 \
  e59594d546b2cc0193b6ed7196c41b5fa6aaf128 \
  64096f71d15cc2745bd0ee13989efd4264d04bc0 \
  ce7566abb3302c63da61aa26ee6dada8d5762f0d \
  7bb8dd280574a382f141e8c2ec3fc02581a132db \
  a312542dfc1b58932563d17d29b2bda9baeb47cf \
  28e77f30e774f6ac16c50a214cdb280d12025e6d \
  fd3a50c6d0366672312b414e5ff24690b4c0c174; do
  grep -q "$commit" "$TMP/pass.md" || fail "report omits source commit $commit"
done
grep -q 'installed `' "$TMP/pass.md" || fail "report omits installed heads"
grep -q 'start `' "$TMP/pass.md" || fail "report omits probe start times"
grep -q 'finish `' "$TMP/pass.md" || fail "report omits probe finish times"
grep -q 'verdict `PASS`' "$TMP/pass.md" || fail "report omits probe verdicts"

python3 - "$TMP/pass.json" "$TMP/short.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
data["lastdb"]["samples"][-1]["sampled_at"] = 3700
json.dump(data, open(sys.argv[2], "w"))
PY
if "$BIN" --live --fixture "$TMP/short.json" --report "$TMP/short.md" >/dev/null 2>&1; then
  fail "a short LastDB window must remain open"
fi
[ "$(head -n 1 "$TMP/short.md")" = PENDING ] || fail "a short soak must write PENDING"
grep -q 'needs 83710s more' "$TMP/short.md" || fail "a short soak must name its remaining time"

python3 - "$TMP/pass.json" "$TMP/restart.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
data["lastdb"]["samples"][-1]["process_start_ts"] = 2000
json.dump(data, open(sys.argv[2], "w"))
PY
if "$BIN" --live --fixture "$TMP/restart.json" --report "$TMP/restart.md" >/dev/null 2>&1; then
  fail "a restart inside the soak must remain open"
fi
[ "$(head -n 1 "$TMP/restart.md")" = PENDING ] || fail "a restart must reset to PENDING"
grep -q 'crosses a LastDB restart' "$TMP/restart.md" || fail "restart reason is missing"

python3 - "$TMP/pass.json" "$TMP/stale.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
data["components"]["fkanban"]["fixes"][0]["present"] = False
json.dump(data, open(sys.argv[2], "w"))
PY
if "$BIN" --live --fixture "$TMP/stale.json" --report "$TMP/stale.md" >/dev/null 2>&1; then
  fail "a stale installed artifact must remain open"
fi
[ "$(head -n 1 "$TMP/stale.md")" = PENDING ] || fail "a stale artifact must write PENDING"

python3 - "$TMP/pass.json" "$TMP/fail.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
data["probes"]["provider_fallback"]["status"] = "fail"
data["probes"]["provider_fallback"]["reason"] = "the chain stopped"
json.dump(data, open(sys.argv[2], "w"))
PY
if "$BIN" --live --fixture "$TMP/fail.json" --report "$TMP/fail.md" >/dev/null 2>&1; then
  fail "a failed live probe must fail the command"
fi
[ "$(head -n 1 "$TMP/fail.md")" = FAIL ] || fail "a failed probe must write FAIL"

NORTH_STAR_PROOF_DIR="$TMP/offline" "$BIN" --offline >/dev/null
[ "$(head -n 1 "$TMP/offline/north-star-feature-delivery-effective-flow.md")" = PENDING-OFFLINE ] \
  || fail "offline proof must never satisfy the live DONE-WHEN rule"

"$RUNNER" --list | grep -qx north-star-feature-delivery-effective-flow \
  || fail "the generic North Star runner does not discover this proof"
NORTH_STAR_PROOF_DIR="$TMP/runner-offline" "$RUNNER" --offline north-star-feature-delivery-effective-flow >/dev/null
[ "$(head -n 1 "$TMP/runner-offline/north-star-feature-delivery-effective-flow.md")" = PENDING-OFFLINE ] \
  || fail "the generic runner wrote a terminal result in offline mode"

jq -e '
  .apps[] | select(.app == "last-stack") |
  any(.links[];
    .source == "bin/last-stack-feature-delivery-effective-flow-proof" and
    .target == "$HOME/.local/bin/last-stack-feature-delivery-effective-flow-proof")
' "$ROOT/config/host-track/apps.json" >/dev/null \
  || fail "Host Track does not publish the proof command"

printf 'ok last-stack-feature-delivery-effective-flow-proof\n'
