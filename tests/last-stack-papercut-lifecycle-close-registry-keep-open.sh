#!/usr/bin/env bash
# papercut-lifecycle-registry-close-ignores-keep-open-20261007: try_registry_close()
# used to close a typed open record `fixed` once its COVERED registry entry's
# card went `done`, without ever reading the record's own `Keep-open:` marker
# first. close_review_records() already honored that marker (the record is the
# authority on whether its own claim is resolved); the registry arm ran before
# it in main() and could close the SAME record close_review_records would have
# skipped. This exercises try_registry_close directly: a COVERED+done record
# that asserts Keep-open must be skipped (reason keep_open_asserted) and must
# never reach `brain papercut close`; a sibling COVERED+done record with no
# such marker must still close normally (the fix must not break the existing
# path); and `--ignore-keep-open` must still override both, matching the
# review-ref arm's operator escape hatch.
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

## Entries

### papercut-keep-open-guarded
- Invariant: fixture invariant for a covered fix whose record still asserts Keep-open
- Guard: fixture compound test
- Prevention: COVERED
- Evidence: card done; registry already flipped COVERED
- Card: card-keep-open

### papercut-normal-close
- Invariant: fixture invariant for a covered fix with no standing claim
- Guard: fixture compound test
- Prevention: COVERED
- Evidence: card done; registry already flipped COVERED
- Card: card-normal
EOF

cat >"$bin_dir/kanban" <<SH
#!/usr/bin/env bash
set -euo pipefail
case "\$*" in
  "show card-keep-open --json")
    printf '%s\n' '{"slug":"card-keep-open","column":"done","body":"PROOF: fixture guard lands and passes."}'
    ;;
  "show card-normal --json")
    printf '%s\n' '{"slug":"card-normal","column":"done","body":"PROOF: fixture guard lands and passes."}'
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
  "get papercut-keep-open-guarded --type papercut --json")
    printf '%s\n' '{"slug":"papercut-keep-open-guarded","status":"open","body":"Status: OPEN\nKeep-open: this record stays open until the end-to-end live check runs, not only the write-free half.\nEvidence: fixture"}'
    ;;
  "get papercut-normal-close --type papercut --json")
    printf '%s\n' '{"slug":"papercut-normal-close","status":"open","body":"Status: OPEN\nEvidence: fixture"}'
    ;;
  "papercut list --status open --index-only --json")
    printf '%s\n' '{"rows":[],"total":0,"method":"index-only (fixture)"}'
    ;;
  papercut\ close\ papercut-keep-open-guarded*)
    printf 'CLOSE %s\n' "\$*" >>"\$BRAIN_APPEND_LOG"
    ;;
  papercut\ close\ papercut-normal-close*)
    printf 'CLOSE %s\n' "\$*" >>"\$BRAIN_APPEND_LOG"
    ;;
  *)
    echo "unexpected brain args: \$*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/brain"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- default run: the keep-open record must be skipped, never closed; the
# plain record must still close normally.
export BRAIN_APPEND_LOG="$tmp/appends.log"
: >"$BRAIN_APPEND_LOG"
PATH="$bin_dir:$PATH" "$HELPER" --limit 200 --json >"$tmp/live.json"

if grep -q 'papercut-keep-open-guarded' "$BRAIN_APPEND_LOG"; then
  fail "a record asserting Keep-open was closed by the registry arm"
fi
grep -q '^CLOSE papercut close papercut-normal-close --status fixed ' "$BRAIN_APPEND_LOG" \
  || fail "the unguarded sibling record was not closed (the fix broke the existing path)"

python3 - "$tmp/live.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
skipped = " ".join(str(s) for s in d.get("skipped", []))
assert "papercut-keep-open-guarded:keep_open_asserted" in skipped, skipped
assert d["fixed"] == 1, f"expected exactly the unguarded record to close: {d}"
PY
echo "ok: Keep-open record skipped with keep_open_asserted; unguarded sibling still closes"

# --- --ignore-keep-open is the named operator override; it must still close
# the guarded record too, matching close_review_records' own escape hatch.
: >"$BRAIN_APPEND_LOG"
PATH="$bin_dir:$PATH" "$HELPER" --limit 200 --ignore-keep-open --json >"$tmp/override.json"
grep -q '^CLOSE papercut close papercut-keep-open-guarded --status fixed ' "$BRAIN_APPEND_LOG" \
  || fail "--ignore-keep-open did not override the registry arm's keep-open skip"
echo "ok: --ignore-keep-open overrides the registry arm's keep-open skip"

echo "PASS last-stack-papercut-lifecycle-close-registry-keep-open"
