#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-milestone-slice-satisfaction"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/src"
git -C "$repo" init -q
git -C "$repo" config user.name fixture
git -C "$repo" config user.email fixture@example.invalid
cat >"$repo/src/feature.txt" <<'EOF'
claim_coherent=true
flow_ledger=true
installed_fix=bounded-board-write
EOF
git -C "$repo" add src/feature.txt
git -C "$repo" commit -qm fixture
main_oid="$(git -C "$repo" rev-parse HEAD)"

cat >"$tmp/reviews.json" <<'EOF'
[{"id":"cr-shipped","state":"merged","merge_oid":"merge-one"}]
EOF
cat >"$tmp/closeouts.json" <<'EOF'
[{"slug":"duplicate-old-card","proof":"PROOF: merged and installed"}]
EOF
cat >"$tmp/memory.md" <<'EOF'
SATISFACTION-CHECK prior candidate=duplicate-old-card verdict=already-satisfied
EOF

run_check() {
  local want="$1" proposal="$2" out="$3" rc
  set +e
  "$bin" --proposal "$proposal" --repo-path "$repo" --base-ref HEAD \
    --expected-main-oid "$main_oid" --merged-reviews "$tmp/reviews.json" \
    --closeouts "$tmp/closeouts.json" --driver-memory "$tmp/memory.md" \
    --json >"$out" 2>"$tmp/stderr"
  rc=$?
  set -e
  [ "$rc" -eq "$want" ] || fail "expected rc=$want got rc=$rc: $(cat "$out") $(cat "$tmp/stderr")"
}

cat >"$tmp/shipped.json" <<'EOF'
{"milestone":"ms-one","candidate":"already-shipped","repo":"EdgeVector/example","clauses":[
{"id":"claim","text":"A claim is coherent.","verdict":"satisfied","evidence":[
{"source":"repo_main","path":"src/feature.txt","contains":"claim_coherent=true"},
{"source":"merged_reviews","contains":"cr-shipped"}]},
{"id":"flow","text":"The flow ledger exists.","verdict":"satisfied","evidence":[
{"source":"repo_main","path":"src/feature.txt","contains":"flow_ledger=true"},
{"source":"driver_memory","contains":"duplicate-old-card"}]}]}
EOF
run_check 2 "$tmp/shipped.json" "$tmp/shipped.out"
jq -e '.verdict == "already-satisfied" and (.remaining_clauses | length) == 0' \
  "$tmp/shipped.out" >/dev/null || fail "wholly shipped verdict"

cat >"$tmp/partial.json" <<'EOF'
{"milestone":"ms-one","candidate":"partly-shipped","repo":"EdgeVector/example","clauses":[
{"id":"claim","text":"A claim is coherent.","verdict":"satisfied","evidence":[
{"source":"repo_main","path":"src/feature.txt","contains":"claim_coherent=true"}]},
{"id":"preflight","text":"The satisfaction preflight exists.","verdict":"unsatisfied","evidence":[
{"source":"repo_main","path":"src/feature.txt","not_contains":"satisfaction_preflight=true"}]}]}
EOF
run_check 0 "$tmp/partial.json" "$tmp/partial.out"
jq -e '.verdict == "partial" and .remaining_clauses == [{"id":"preflight","text":"The satisfaction preflight exists."}]' \
  "$tmp/partial.out" >/dev/null || fail "partial must return only unsatisfied clauses"

cat >"$tmp/fresh.json" <<'EOF'
{"milestone":"ms-one","candidate":"fresh-slice","repo":"EdgeVector/example","clauses":[
{"id":"new-one","text":"The first new behavior exists.","verdict":"unsatisfied","evidence":[
{"source":"repo_main","path":"src/feature.txt","not_contains":"new_one=true"}]},
{"id":"new-two","text":"The second new behavior exists.","verdict":"unsatisfied","evidence":[
{"source":"repo_main","path":"src/feature.txt","not_contains":"new_two=true"}]}]}
EOF
run_check 0 "$tmp/fresh.json" "$tmp/fresh.out"
jq -e '.verdict == "fresh" and (.remaining_clauses | length) == 2' \
  "$tmp/fresh.out" >/dev/null || fail "fresh verdict"

cat >"$tmp/unknown.json" <<'EOF'
{"milestone":"ms-one","candidate":"unknown-slice","repo":"EdgeVector/example","clauses":[
{"id":"unknown-one","text":"The remote product proof exists.","verdict":"unknown",
"reason":"No product-proof record names this behavior."}]}
EOF
run_check 3 "$tmp/unknown.json" "$tmp/unknown.out"
jq -e '.verdict == "unknown" and (.unknown_clauses | length) == 1' \
  "$tmp/unknown.out" >/dev/null || fail "unknown must block"

cat >"$tmp/stale-papercut.json" <<'EOF'
{"milestone":"ms-one","candidate":"duplicate-old-card","repo":"EdgeVector/example","clauses":[
{"id":"bounded-write","text":"The board write is bounded.","verdict":"satisfied","evidence":[
{"source":"repo_main","path":"src/feature.txt","contains":"installed_fix=bounded-board-write"},
{"source":"closeouts","contains":"duplicate-old-card"},
{"source":"merged_reviews","contains":"merge-one"}]}]}
EOF
run_check 2 "$tmp/stale-papercut.json" "$tmp/stale-papercut.out"
jq -e '.verdict == "already-satisfied" and .sources.repo_main.oid == $oid' \
  --arg oid "$main_oid" "$tmp/stale-papercut.out" >/dev/null \
  || fail "stale papercut must use exact main and create no card"

cat >"$tmp/unsupported.json" <<'EOF'
{"milestone":"ms-one","candidate":"unsupported","repo":"EdgeVector/example","clauses":[
{"id":"missing","text":"A missing feature exists.","verdict":"satisfied","evidence":[
{"source":"repo_main","path":"src/feature.txt","contains":"missing=true"}]}]}
EOF
run_check 3 "$tmp/unsupported.json" "$tmp/unsupported.out"
jq -e '.verdict == "unknown" and (.remaining_clauses | length) == 0' \
  "$tmp/unsupported.out" >/dev/null || fail "unsupported satisfied claim must block"

jq -e '
  .apps[] | select(.app == "last-stack") |
  any(.links[];
    .source == "bin/last-stack-milestone-slice-satisfaction" and
    .target == "$HOME/.local/bin/last-stack-milestone-slice-satisfaction")
' "$ROOT/config/host-track/apps.json" >/dev/null \
  || fail "host-track does not publish the satisfaction gate"

printf 'ok last-stack-milestone-slice-satisfaction\n'
