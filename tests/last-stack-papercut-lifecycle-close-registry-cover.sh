#!/usr/bin/env bash
# The prevention registry's write-back half: an entry can sit at
# `Prevention: MISSING` forever even after its card lands a real, proven
# guard, because nothing ever revisited it
# (papercut-registry-write-back-not-run-after-card-done-20260925). This
# exercises `try_registry_cover`: it must flip MISSING to COVERED only when
# the card is `done` AND its own latest status marker is a bare PROOF/RUNTIME
# line, must leave a done-but-unproven or still-doing card alone, must read
# both registry dialects (the documented `### ` block and the one-line
# flat-append form already in live use), and must never write on --dry-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="$ROOT/bin/last-stack-papercut-lifecycle-close"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

bin_dir="$tmp/bin"
mkdir -p "$bin_dir"

cat >"$tmp/registry.txt" <<'EOF'
# Papercut prevention registry

Entry format (the helper parses exactly these lines):

    ### papercut-<slug>
    - Invariant: <cross-boundary failure invariant>
    - Guard: <compound test or probe locator>
    - Prevention: MISSING | COVERED | NOT_APPLICABLE
    - Evidence: <passing executable proof; never prose or a merge alone>
    - Card: <card-slug>

## Entries

### papercut-cover-me
- Invariant: fixture invariant for a covered fix
- Guard: fixture compound test
- Prevention: MISSING
- Evidence: card filed; proof not yet run
- Card: card-covered

### papercut-pending-hold
- Invariant: fixture invariant for a fix still validating
- Guard: fixture compound test
- Prevention: MISSING
- Evidence: card filed; proof not yet run
- Card: card-pending

### papercut-still-doing
- Invariant: fixture invariant for a fix still in progress
- Guard: fixture compound test
- Prevention: MISSING
- Evidence: card filed; proof not yet run
- Card: card-doing

2026-09-24T00:00:00Z papercut-flat-cover | invariant: fixture flat-format invariant | compound-test: fixture flat-format guard | MISSING | card:card-flat | evidence: prerequisite card filed in backlog; proof not yet run

papercut-flat-cover-no-timestamp | invariant: fixture flat-format invariant with no leading timestamp | compound-test: fixture flat-format guard | MISSING | card:card-flat-no-ts | evidence: prerequisite card filed in backlog; proof not yet run

### papercut-already-covered
- Invariant: fixture invariant already marked covered
- Guard: fixture compound test
- Prevention: COVERED
- Evidence: prior pass already confirmed this one
- Card: card-x
EOF

cat >"$bin_dir/kanban" <<SH
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "show card-covered --json")
    printf '%s\n' '{"slug":"card-covered","column":"done","body":"PROGRESS: working it\nPROOF: fixture 3-case regression passes against the installed binary. http://forge.example/EdgeVector/demo/pulls/9"}'
    ;;
  "show card-pending --json")
    printf '%s\n' '{"slug":"card-pending","column":"done","body":"PROOF: fixture regression passes.\nDEPLOY-PENDING 2026-09-24: waiting on the normal one-hour soak before this counts as proven."}'
    ;;
  "show card-doing --json")
    printf '%s\n' '{"slug":"card-doing","column":"doing","body":"PROGRESS: still working it"}'
    ;;
  "show card-flat --json")
    printf '%s\n' '{"slug":"card-flat","column":"done","body":"MERGED 2026-09-24: merged abc123.\nRUNTIME: fixture confirms the installed binary carries the fix."}'
    ;;
  "show card-flat-no-ts --json")
    printf '%s\n' '{"slug":"card-flat-no-ts","column":"done","body":"PROOF: fixture confirms the no-timestamp flat entry parses too."}'
    ;;
  "show card-x --json")
    printf '%s\n' '{"slug":"card-x","column":"todo","body":"PROGRESS: not started"}'
    ;;
  *)
    echo "unexpected kanban args: \$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/kanban"

cat >"$bin_dir/brain" <<SH
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "get papercut-prevention-registry --type reference")
    cat "$tmp/registry.txt"
    ;;
  "append papercut-prevention-registry --type reference")
    cat >>"\$BRAIN_APPEND_LOG"
    ;;
  "papercut list --status open --index-only --json")
    printf '%s\n' '{"rows":[],"total":0,"method":"index-only (fixture)"}'
    ;;
  *)
    echo "unexpected brain args: \$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/brain"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- dry-run must scan and decide, but write nothing.
export BRAIN_APPEND_LOG="$tmp/dry-appends.log"
: >"$BRAIN_APPEND_LOG"
PATH="$bin_dir:$PATH" "$HELPER" --limit 200 --dry-run --json >"$tmp/dry.json"
[ ! -s "$BRAIN_APPEND_LOG" ] || fail "dry-run wrote to the registry"
python3 - "$tmp/dry.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["registry_covered"] == 0, f"dry-run must not report covered: {d}"
assert d["registry_cover_scanned"] == 5, f"dry-run should still scan the 5 MISSING candidates: {d}"
PY
echo "ok: dry-run scans MISSING entries and writes nothing"

# --- live pass flips the three confirmed entries and leaves the rest alone.
export BRAIN_APPEND_LOG="$tmp/appends.log"
: >"$BRAIN_APPEND_LOG"
PATH="$bin_dir:$PATH" "$HELPER" --limit 200 --json >"$tmp/live.json"
python3 - "$tmp/live.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["registry_covered"] == 3, f"expected 3 covered, got {d.get('registry_covered')}: {d}"
assert d["registry_cover_scanned"] == 5, f"expected 5 MISSING candidates scanned: {d}"
skipped = " ".join(str(s) for s in d.get("skipped", []))
assert "papercut-pending-hold:no_confirmed_proof" in skipped, skipped
assert "papercut-still-doing:card_not_done" in skipped, skipped
PY
echo "ok: live pass reports 2 covered, holds the pending/doing entries"

grep -q 'papercut-cover-me STATUS-UPDATE: Prevention MISSING -> COVERED | card:card-covered (done)' "$BRAIN_APPEND_LOG" \
  || fail "block-format MISSING entry was not written back COVERED"
grep -q 'card:card-covered done; PROOF: fixture 3-case regression passes against the installed binary\. http://forge\.example/EdgeVector/demo/pulls/9' "$BRAIN_APPEND_LOG" \
  || fail "covered evidence did not carry the PROOF line and PR link"

grep -q 'papercut-flat-cover STATUS-UPDATE: Prevention MISSING -> COVERED | card:card-flat (done)' "$BRAIN_APPEND_LOG" \
  || fail "flat one-line MISSING entry (with a leading timestamp) was not written back COVERED"
grep -q 'card:card-flat done; RUNTIME: fixture confirms the installed binary carries the fix' "$BRAIN_APPEND_LOG" \
  || fail "covered evidence did not carry the RUNTIME marker"

grep -q 'papercut-flat-cover-no-timestamp STATUS-UPDATE: Prevention MISSING -> COVERED | card:card-flat-no-ts (done)' "$BRAIN_APPEND_LOG" \
  || fail "flat one-line MISSING entry with NO leading timestamp was not written back COVERED (this exact shape is live in the real registry today)"

if grep -q 'papercut-pending-hold' "$BRAIN_APPEND_LOG"; then
  fail "a card whose latest marker is DEPLOY-PENDING must not be marked COVERED"
fi
if grep -q 'papercut-still-doing' "$BRAIN_APPEND_LOG"; then
  fail "a card still in doing must not be marked COVERED"
fi
if grep -q 'papercut-already-covered' "$BRAIN_APPEND_LOG"; then
  fail "an already-COVERED entry must not be re-scanned by the MISSING pass"
fi
echo "ok: appended status-update lines match the expected shape and nothing else was touched"

python3 - "$tmp/live.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
skipped = " ".join(str(s) for s in d.get("skipped", []))
assert "papercut-<slug>" not in skipped, (
    "the doc's own '### papercut-<slug>' template block (inside an indented "
    f"code fence) was parsed as a real registry entry: {skipped}"
)
PY
echo "ok: the doc's own 'Entry format' template block is not parsed as a real entry"

echo "PASS last-stack-papercut-lifecycle-close-registry-cover"
