#!/usr/bin/env bash
# Hermetic fixtures for last-stack-kanban-file-pr (no live board writes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-kanban-file-pr"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$bin" ] || chmod +x "$bin"
bash -n "$bin" || fail "bash -n"

"$bin" --help >/dev/null 2>&1 && fail "bare --help as slug should be usage"
"$bin" 2>/dev/null && fail "expected usage failure"

mkdir -p "$tmp/bin" "$tmp/empty-fixture"
: >"$tmp/add.log"
: >"$tmp/ms-add.log"
: >"$tmp/add.body"
export LAST_STACK_DECISION_FIXTURE="$tmp/empty-fixture"

# Offline admission record: ns-a is the admitted primary, ns-paused is not.
# decision-2026-08-31-two-admitted-feature-outcomes
admission_fix="$tmp/admission-fixture"
mkdir -p "$admission_fix/get"
cat >"$admission_fix/get/preference-feature-delivery-portfolio-admission.txt" <<'EOF'
[preference] preference-feature-delivery-portfolio-admission
title:      Feature delivery portfolio admission
---
Policy-Version: 1
Primary: ns-a
Secondary: ns-b
Paused: all-other-feature-north-stars
Updated-At: 2026-08-31T17:45:00Z
EOF
export LAST_STACK_ADMISSION_FIXTURE="$admission_fix"

cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
shift || true
case "$cmd" in
  milestone)
    sub="${1:-}"
    shift || true
    if [ "$sub" = "show" ]; then
      slug="${1:-}"
      case "$slug" in
        ms-live)
          printf '{"slug":"ms-live","state":"active","north_star":"ns-a"}\n'
          ;;
        ms-done)
          printf '{"slug":"ms-done","state":"complete","north_star":"ns-a"}\n'
          ;;
        ms-other-ns)
          printf '{"slug":"ms-other-ns","state":"active","north_star":"ns-b"}\n'
          ;;
        *)
          exit 1
          ;;
      esac
    elif [ "$sub" = "add" ]; then
      printf '%s\n' "$*" >>"${FILE_PR_MS_ADD_LOG:-/tmp/ms-add.log}"
      exit 0
    else
      echo "unexpected milestone $sub $*" >&2
      exit 1
    fi
    ;;
  add)
    printf '%s\n' "$*" >>"${FILE_PR_ADD_LOG:-/tmp/add.log}"
    cat >"${FILE_PR_ADD_BODY:-/tmp/add.body}"
    exit 0
    ;;
  *)
    echo "unexpected kanban $cmd $*" >&2
    exit 1
    ;;
esac
SH
chmod +x "$tmp/bin/kanban"

export FILE_PR_ADD_LOG="$tmp/add.log"
export FILE_PR_MS_ADD_LOG="$tmp/ms-add.log"
export FILE_PR_ADD_BODY="$tmp/add.body"
# Keep host kanban off PATH; always pass --board-cli so the helper cannot
# pick up ~/.local/bin/kanban (the helper prepends that dir).
export PATH="/usr/bin:/bin"
fake_kanban="$tmp/bin/kanban"

body_ok="$(mktemp "$tmp/body.XXXX")"
cat >"$body_ok" <<'EOF'
**Follow the kanban-agent skill — drive this through to a MERGED PR.**

Repo: EdgeVector/last-stack
Base: main
Kind: pr

## GOAL
File pickup-ready cards.

## END STATE
Generators attach a live north star and milestone at add time.
EOF

# usage: missing flags
if "$bin" some-slug --board-cli "$fake_kanban" --title "x" --repo EdgeVector/last-stack <"$body_ok" 2>/dev/null; then
  fail "should refuse missing --north-star/--milestone"
fi

# refuse complete milestone
if "$bin" some-slug --board-cli "$fake_kanban" --title "x" --repo EdgeVector/last-stack \
  --north-star ns-a --milestone ms-done <"$body_ok" 2>/dev/null; then
  fail "should refuse complete milestone"
fi

# refuse NS mismatch
if "$bin" some-slug --board-cli "$fake_kanban" --title "x" --repo EdgeVector/last-stack \
  --north-star ns-a --milestone ms-other-ns <"$body_ok" 2>/dev/null; then
  fail "should refuse north-star mismatch"
fi

# refuse hollow body
if printf 'just a note\n' | "$bin" some-slug --board-cli "$fake_kanban" --title "x" --repo EdgeVector/last-stack \
  --north-star ns-a --milestone ms-live 2>/dev/null; then
  fail "should refuse hollow body"
fi

# happy path
: >"$tmp/add.log"
out="$("$bin" ship-login --board-cli "$fake_kanban" --title "Ship login" --repo EdgeVector/last-stack \
  --north-star ns-a --milestone ms-live --priority P1 --tags factory <"$body_ok")" \
  || fail "happy path failed: $out"
printf '%s\n' "$out" | grep -q 'filed ship-login column=todo north_star=ns-a milestone=ms-live' \
  || fail "happy stdout: $out"
grep -q 'ship-login --title Ship login' "$tmp/add.log" \
  || fail "add log title: $(cat "$tmp/add.log")"
grep -q -- '--north-star ns-a' "$tmp/add.log" || fail "add log ns: $(cat "$tmp/add.log")"
grep -q -- '--milestone ms-live' "$tmp/add.log" || fail "add log ms: $(cat "$tmp/add.log")"
grep -q -- '--kind pr' "$tmp/add.log" || fail "add log kind: $(cat "$tmp/add.log")"
grep -q -- '--column todo' "$tmp/add.log" || fail "add log column: $(cat "$tmp/add.log")"
grep -q '## DECISION-CHECK' "$tmp/add.body" || fail "missing DECISION-CHECK stamp: $(cat "$tmp/add.body")"
grep -q 'verdict: clear' "$tmp/add.body" || fail "empty fixture should stamp clear: $(cat "$tmp/add.body")"
grep -q 'slugs: none' "$tmp/add.body" || fail "empty fixture slugs: $(cat "$tmp/add.body")"

# missing milestone without --ensure-milestone
if "$bin" new-card --board-cli "$fake_kanban" --title "x" --repo EdgeVector/last-stack \
  --north-star ns-a --milestone ms-new <"$body_ok" 2>/dev/null; then
  fail "missing milestone should fail without --ensure-milestone"
fi

# --ensure-milestone creates then files
: >"$tmp/add.log"
: >"$tmp/ms-add.log"
"$bin" new-card --board-cli "$fake_kanban" --title "New card" --repo EdgeVector/last-stack \
  --north-star ns-a --milestone ms-new --ensure-milestone <"$body_ok" \
  || fail "ensure-milestone failed"
grep -q 'ms-new' "$tmp/ms-add.log" || fail "did not create milestone: $(cat "$tmp/ms-add.log")"
grep -q -- '--north-star ns-a' "$tmp/ms-add.log" || fail "create missing ns: $(cat "$tmp/ms-add.log")"
grep -q 'new-card' "$tmp/add.log" || fail "ensure did not add card: $(cat "$tmp/add.log")"

# dry-run does not write
: >"$tmp/add.log"
"$bin" ship-login --board-cli "$fake_kanban" --title "Ship login" --repo EdgeVector/last-stack \
  --north-star ns-a --milestone ms-live --dry-run <"$body_ok" \
  | grep -q 'DRY' || fail "dry-run missing DRY"
if [ -s "$tmp/add.log" ]; then
  fail "dry-run wrote add: $(cat "$tmp/add.log")"
fi

# conflict: retrieved no-review-column + GOAL that restores the review column
conflict_fix="$tmp/conflict-fixture"
mkdir -p "$conflict_fix/get"
cat >"$conflict_fix/search.json" <<'EOF'
[{"slug":"preference-kanban-no-review-column","score":1.0,"type":"preference","title":"no review column","snippet":""}]
EOF
cat >"$conflict_fix/get/preference-kanban-no-review-column.txt" <<'EOF'
[preference] preference-kanban-no-review-column
title:      no review column
---
Kanban columns are backlog, todo, doing, done. No review column.
EOF
body_conflict="$(mktemp "$tmp/body-conflict.XXXX")"
cat >"$body_conflict" <<'EOF'
**Follow the kanban-agent skill — drive this through to a MERGED PR.**

Repo: EdgeVector/last-stack
Base: main
Kind: pr

## GOAL
Add a review column to the default board.

## END STATE
Agents park unfinished PRs in review.
EOF
: >"$tmp/add.log"
set +e
conflict_out="$("$bin" bad-review --board-cli "$fake_kanban" --title "Add a review column" \
  --repo EdgeVector/last-stack --north-star ns-a --milestone ms-live \
  --decision-fixture "$conflict_fix" <"$body_conflict" 2>&1)"
conflict_rc=$?
set -e
[ "$conflict_rc" -eq 2 ] || fail "conflict should exit 2, got $conflict_rc: $conflict_out"
printf '%s\n' "$conflict_out" | grep -q 'decision-check refused' \
  || fail "conflict stdout missing refuse: $conflict_out"
if [ -s "$tmp/add.log" ]; then
  fail "conflict wrote add: $(cat "$tmp/add.log")"
fi

# admission: a paused north star is refused and writes no card
: >"$tmp/add.log"
set +e
paused_out="$("$bin" paused-card --board-cli "$fake_kanban" --title "Paused work" \
  --repo EdgeVector/last-stack --north-star ns-paused --milestone ms-live \
  --admission-fixture "$admission_fix" <"$body_ok" 2>&1)"
paused_rc=$?
set -e
[ "$paused_rc" -eq 2 ] || fail "paused north star should exit 2, got $paused_rc: $paused_out"
printf '%s\n' "$paused_out" | grep -q 'admission refused' \
  || fail "paused refusal message: $paused_out"
if [ -s "$tmp/add.log" ]; then
  fail "paused north star wrote add: $(cat "$tmp/add.log")"
fi

# admission: an unreadable record fails closed and writes no card
: >"$tmp/add.log"
mkdir -p "$tmp/no-admission/get"
set +e
noadm_out="$("$bin" no-admission-card --board-cli "$fake_kanban" --title "x" \
  --repo EdgeVector/last-stack --north-star ns-a --milestone ms-live \
  --admission-fixture "$tmp/no-admission" <"$body_ok" 2>&1)"
noadm_rc=$?
set -e
[ "$noadm_rc" -eq 2 ] || fail "unreadable admission should refuse, got $noadm_rc: $noadm_out"
printf '%s\n' "$noadm_out" | grep -q 'admission record unreadable' \
  || fail "unreadable admission message: $noadm_out"
if [ -s "$tmp/add.log" ]; then
  fail "unreadable admission wrote add: $(cat "$tmp/add.log")"
fi

# admission: repair work is not gated, even with no readable admission record
: >"$tmp/add.log"
"$bin" repair-card --board-cli "$fake_kanban" --title "Repair" \
  --repo EdgeVector/last-stack --north-star ns-a --milestone ms-live \
  --work-class repair --admission-fixture "$tmp/no-admission" <"$body_ok" \
  || fail "repair work-class must bypass admission"
grep -q 'repair-card' "$tmp/add.log" || fail "repair card not filed: $(cat "$tmp/add.log")"

# an unknown work class is a usage error
if "$bin" bad-class --board-cli "$fake_kanban" --title "x" --repo EdgeVector/last-stack \
  --north-star ns-a --milestone ms-live --work-class nonsense <"$body_ok" 2>/dev/null; then
  fail "unknown work-class should be refused"
fi

echo "ok last-stack-kanban-file-pr"
