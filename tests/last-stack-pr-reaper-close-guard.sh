#!/usr/bin/env bash
# Regression: pr-reaper closed green auto-merge CRs whose head never reached
# main (papercut-lastgit-pr-reaper-closes-green-unmerged-cr, p0). The CR left
# the open inventory, so `lastgit stuck` and `cr list --all-open` both read
# empty while the change was off main.
#
# The guard must refuse exactly that shape and stay out of the way of every
# other close, because most unlanded closes on this fleet are correct: of 51
# auto-merge last-stack CRs closed in the 14 days to 2026-09-05, 37 heads never
# reached main and a 12-row sample of those read 8 failure, 2 absent, 2 success.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
guard="$ROOT/bin/last-stack-pr-reaper-close-guard"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

test -x "$guard" || chmod +x "$guard"
bash -n "$guard"

if grep -nE '^[[:space:]]*mapfile ' "$guard" >/dev/null; then
  echo "guard must stay bash-3.2 portable (no mapfile builtin)" >&2
  exit 1
fi

git_bin=/usr/bin/git
[ -x "$git_bin" ] || git_bin="$(command -v git)"

# ── ancestry fixture: main has LANDED; STRAY sits on an unmerged branch ──────
repo="$tmp/repo"
"$git_bin" init --quiet "$repo"
"$git_bin" -C "$repo" config user.email t@example.com
"$git_bin" -C "$repo" config user.name t
echo base > "$repo/f"; "$git_bin" -C "$repo" add f
"$git_bin" -C "$repo" commit --quiet -m base
BASE_PARENT="$("$git_bin" -C "$repo" rev-parse HEAD)"
echo landed > "$repo/f"; "$git_bin" -C "$repo" commit --quiet -am landed
LANDED="$("$git_bin" -C "$repo" rev-parse HEAD)"
MAIN="$LANDED"
"$git_bin" -C "$repo" checkout --quiet -b stray "$BASE_PARENT"
echo stray > "$repo/f"; "$git_bin" -C "$repo" commit --quiet -am stray
STRAY="$("$git_bin" -C "$repo" rev-parse HEAD)"

cr_row() { # cr_row <state> <auto_merge> <head>
  cat <<JSON
{"cr_id":"cr-test-0001","repo":"last-stack","state":"$1","auto_merge":"$2",
 "head_oid":"$3","base_ref":"refs/heads/main","require_status":"ci-required"}
JSON
}
ci_row() { # ci_row <state> [event_id]
  cat <<JSON
{"repo":"last-stack","context":"ci-required","state":"$1","event_id":"${2:-mtah78jw-aeef94a857c3}"}
JSON
}

# run <label> <expected-verdict> <expected-exit> <cr-json> <ci-json>
run() {
  local label="$1" want_verdict="$2" want_exit="$3" crj="$4" cij="$5" rc=0
  "$guard" --repo last-stack --cr cr-test-0001 \
    --cr-json "$crj" --ci-json "$cij" \
    --base-oid "$MAIN" --git-dir "$repo" --no-fetch --json \
    >"$tmp/out.json" 2>"$tmp/out.err" || rc=$?
  local got
  got="$(jq -r '.verdict' "$tmp/out.json" 2>/dev/null || echo PARSE-FAIL)"
  if [ "$got" != "$want_verdict" ] || [ "$rc" != "$want_exit" ]; then
    echo "FAIL $label: want verdict=$want_verdict exit=$want_exit, got verdict=$got exit=$rc" >&2
    cat "$tmp/out.json" "$tmp/out.err" >&2 || true
    exit 1
  fi
  echo "ok   $label ($got, exit $rc)"
}

# ── 1. the defect: green, driving, and not on main ──────────────────────────
cr_row open true "$STRAY" > "$tmp/cr-green.json"
ci_row success > "$tmp/ci-success.json"
run "green unmerged auto-merge refuses" refuse 1 "$tmp/cr-green.json" "$tmp/ci-success.json"
jq -e '.reason == "green-unmerged-auto-merge"' "$tmp/out.json" >/dev/null \
  || { echo "FAIL: refusal must name green-unmerged-auto-merge" >&2; exit 1; }

# ── 2. a real red verdict is the reaper doing its job ───────────────────────
ci_row failure > "$tmp/ci-failure.json"
run "red required check closes" close-ok 0 "$tmp/cr-green.json" "$tmp/ci-failure.json"

# ── 3. the opposite ancestry direction: the work already landed ─────────────
# Guarded explicitly because a check written only against case 1 passes while
# refusing every close of already-landed work, which is the shape a phantom
# merge heal leaves behind.
cr_row open true "$LANDED" > "$tmp/cr-landed.json"
run "head already in base closes" close-ok 0 "$tmp/cr-landed.json" "$tmp/ci-success.json"
jq -e '.reason == "head-already-in-base"' "$tmp/out.json" >/dev/null \
  || { echo "FAIL: landed close must name head-already-in-base" >&2; exit 1; }

# ── 4. nothing is driving it, so the reaper's judgment stands ───────────────
cr_row open false "$STRAY" > "$tmp/cr-noauto.json"
run "not auto-merge closes" close-ok 0 "$tmp/cr-noauto.json" "$tmp/ci-success.json"

# ── 5. an already-terminal CR is not being closed by this decision ──────────
cr_row closed true "$STRAY" > "$tmp/cr-closed.json"
run "already terminal closes" close-ok 0 "$tmp/cr-closed.json" "$tmp/ci-success.json"

# ── 6/7. pending is not evidence that green work should be discarded ────────
ci_row pending "ci-lease:v1:abc123" > "$tmp/ci-live.json"
run "pending under a live lease is indeterminate" indeterminate 3 "$tmp/cr-green.json" "$tmp/ci-live.json"
jq -e '.reason == "required-check-running"' "$tmp/out.json" >/dev/null \
  || { echo "FAIL: leased pending must read required-check-running" >&2; exit 1; }

ci_row pending "mtah78jw-aeef94a857c3" > "$tmp/ci-torn.json"
run "pending with no lease prefix is indeterminate" indeterminate 3 "$tmp/cr-green.json" "$tmp/ci-torn.json"
jq -e '.reason == "required-check-pending-unleased"' "$tmp/out.json" >/dev/null \
  || { echo "FAIL: torn pending must be distinguishable from a live run" >&2; exit 1; }

# ── 8. no required-check row at all ────────────────────────────────────────
echo '{}' > "$tmp/ci-absent.json"
run "absent required check is indeterminate" indeterminate 3 "$tmp/cr-green.json" "$tmp/ci-absent.json"

# ── 9. the required context is read by name, not by position ───────────────
cat > "$tmp/ci-multi.json" <<'JSON'
{"checks":[{"context":"lint","state":"failure","event_id":"x"},
           {"context":"ci-required","state":"success","event_id":"y"}]}
JSON
run "reads the required context by name" refuse 1 "$tmp/cr-green.json" "$tmp/ci-multi.json"

# ── 10. an unreadable CR row fails closed, never open ──────────────────────
echo 'not json' > "$tmp/cr-bad.json"
run "unreadable CR row fails closed" indeterminate 3 "$tmp/cr-bad.json" "$tmp/ci-success.json"

# ── 11. the prompt must actually run the guard ─────────────────────────────
# A helper nothing calls is not a guard. This is the half that failed before:
# routines/pr-reaper.md STEP 2 had a two-branch ladder and no call site.
prompt="$ROOT/routines/pr-reaper.md"
grep -q 'bin/last-stack-pr-reaper-close-guard' "$prompt" \
  || { echo "FAIL: routines/pr-reaper.md must invoke the close guard" >&2; exit 1; }
for token in 'close-refused-green-unmerged' 'close-indeterminate'; do
  grep -q "$token" "$prompt" \
    || { echo "FAIL: pr-reaper.md must heartbeat $token so the refusal stays measurable" >&2; exit 1; }
done
# The call site must precede the close verbs it gates, or it gates nothing.
guard_line="$(grep -n 'bin/last-stack-pr-reaper-close-guard' "$prompt" | head -1 | cut -d: -f1)"
close_line="$(grep -n 'lastgit cr close' "$prompt" | tail -1 | cut -d: -f1)"
if [ -z "$guard_line" ] || [ -z "$close_line" ] || [ "$guard_line" -gt "$close_line" ]; then
  echo "FAIL: the guard must be introduced before the last close verb (guard=$guard_line close=$close_line)" >&2
  exit 1
fi
echo "ok   pr-reaper.md wires the guard ahead of its close verbs"

echo "PASS last-stack-pr-reaper-close-guard"
