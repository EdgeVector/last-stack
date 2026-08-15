#!/usr/bin/env bash
# Regression: inventory lists merged CRs as open → heal reports ok + healed_stale_open,
# never classifies pure projection lag as error / stale-open-projection error-flag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
helper="$ROOT/bin/last-stack-pr-reaper-stale-open-heal"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

test -x "$helper" || chmod +x "$helper"
bash -n "$helper"

if grep -nE '^[[:space:]]*mapfile ' "$helper" >/dev/null; then
  echo "helper must stay bash-3.2 portable (no mapfile builtin)" >&2
  exit 1
fi

# ── Fixture: 3 inventory-"open" rows that reconcile reports as stale ────────
cat >"$tmp/inventory.json" <<'JSON'
[
  {
    "cr_key": "fkanban:cr-mss11ybr-b557",
    "cr_id": "cr-mss11ybr-b557",
    "repo": "fkanban",
    "state": "open",
    "title": "already merged A"
  },
  {
    "cr_key": "last-stack:cr-mss2opm6-1fa0",
    "cr_id": "cr-mss2opm6-1fa0",
    "repo": "last-stack",
    "state": "open",
    "title": "already merged B"
  },
  {
    "cr_key": "routines:cr-msszxu83-4fb0",
    "cr_id": "cr-msszxu83-4fb0",
    "repo": "routines",
    "state": "open",
    "title": "already merged C"
  }
]
JSON

cat >"$tmp/reconcile.json" <<'JSON'
{
  "missing": [],
  "stale": [
    {
      "cr_key": "fkanban:cr-mss11ybr-b557",
      "cr_id": "cr-mss11ybr-b557",
      "repo": "fkanban",
      "state": "open"
    },
    {
      "cr_key": "last-stack:cr-mss2opm6-1fa0",
      "cr_id": "cr-mss2opm6-1fa0",
      "repo": "last-stack",
      "state": "open"
    },
    {
      "cr_key": "routines:cr-msszxu83-4fb0",
      "cr_id": "cr-msszxu83-4fb0",
      "repo": "routines",
      "state": "open"
    }
  ],
  "indexed": 3,
  "truth": 0,
  "repaired": false
}
JSON

out="$("$helper" --json --dry-run --no-point \
  --inventory "$tmp/inventory.json" \
  --reconcile-json "$tmp/reconcile.json")"

echo "$out" | jq -e '.outcome == "ok"' >/dev/null
echo "$out" | jq -e '.healed_stale_open == 3' >/dev/null
echo "$out" | jq -e '.inventory_open_before == 3' >/dev/null
echo "$out" | jq -e '.inventory_open_after == 0' >/dev/null
echo "$out" | jq -e '.reason == "healed-stale-open-projection"' >/dev/null

# Must NOT look like the legacy error classification
if printf '%s\n' "$out" | jq -e '.outcome == "error"' >/dev/null 2>&1; then
  echo "FAIL: outcome must not be error for stale-open projection" >&2
  echo "$out" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -q 'stale-open-projection:'; then
  echo "FAIL: must not emit legacy stale-open-projection:N-point-merged error flag" >&2
  echo "$out" >&2
  exit 1
fi
# flagged may mention healed_stale_open but not error-class projection
echo "$out" | jq -e '.flagged | map(test("healed_stale_open")) | any' >/dev/null

# ── Empty inventory → noop ──────────────────────────────────────────────────
echo '[]' >"$tmp/empty.json"
cat >"$tmp/recon-empty.json" <<'JSON'
{"missing":[],"stale":[],"indexed":0,"truth":0,"repaired":false}
JSON
out2="$("$helper" --json --no-point \
  --inventory "$tmp/empty.json" \
  --reconcile-json "$tmp/recon-empty.json")"
echo "$out2" | jq -e '.outcome == "noop"' >/dev/null
echo "$out2" | jq -e '.healed_stale_open == 0' >/dev/null

# ── Partial stale (1 of 2) ──────────────────────────────────────────────────
cat >"$tmp/inv2.json" <<'JSON'
[
  {"cr_key":"a:cr-1","cr_id":"cr-1","repo":"a","state":"open"},
  {"cr_key":"b:cr-2","cr_id":"cr-2","repo":"b","state":"open"}
]
JSON
cat >"$tmp/recon2.json" <<'JSON'
{
  "missing": [],
  "stale": [{"cr_key":"a:cr-1","cr_id":"cr-1","repo":"a","state":"open"}],
  "indexed": 2,
  "truth": 1,
  "repaired": true
}
JSON
out3="$("$helper" --json --no-point \
  --inventory "$tmp/inv2.json" \
  --reconcile-json "$tmp/recon2.json")"
echo "$out3" | jq -e '.outcome == "ok"' >/dev/null
echo "$out3" | jq -e '.healed_stale_open == 1' >/dev/null
echo "$out3" | jq -e '.inventory_open_after == 1' >/dev/null

# ── Helper exit code always 0 on fixture path ───────────────────────────────
set +e
"$helper" --json --no-point \
  --inventory "$tmp/inventory.json" \
  --reconcile-json "$tmp/reconcile.json" >/dev/null
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  echo "FAIL: helper exit code must be 0 for projection lag (got $rc)" >&2
  exit 1
fi

echo "PASS: last-stack-pr-reaper-stale-open-heal fixtures"
