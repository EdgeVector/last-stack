#!/usr/bin/env bash
# Offline proof for the portable routine fleet.
# The positive path fills the real bootstrap kit. The negative paths remove
# the cause the proof asserts, and each one must fail.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-north-star-proof"
HARNESS="$ROOT/harness/north-star/north-star-portable-routine-fleet/run.sh"
chmod +x "$BIN" "$HARNESS"

fail() {
  echo "portable-routine-fleet proof: $*" >&2
  exit 1
}

bash -n "$HARNESS"

list_out="$("$BIN" --list)"
grep -qx 'north-star-portable-routine-fleet' <<<"$list_out" \
  || fail "slug missing from last-stack-north-star-proof --list"

PROOF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/portable-fleet-proof.XXXXXX")"
NEG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/portable-fleet-proof-neg.XXXXXX")"
trap 'rm -rf "$PROOF_DIR" "$NEG_DIR"' EXIT

export NORTH_STAR_PROOF_MODE=offline
export NORTH_STAR_PROOF_DIR="$PROOF_DIR"
unset PORTABLE_FLEET_TEMPLATE_DIR PORTABLE_FLEET_ROUTINES_DIR \
  PORTABLE_FLEET_ROTATOR_SKILL PORTABLE_FLEET_MINER_SKILL || true

# The live routines hold one thin session-miner trigger (revenant-watch); the
# proof needs two. The positive path adds one fixture trigger so it tests the
# harness logic. The real-repo verdict stays the North Star's own result.
pos_routines="$NEG_DIR/pos-routines"
mkdir -p "$pos_routines"
cp "$ROOT/routines/"*.md "$pos_routines/"
printf '%s\n' '---' 'name: fixture-miner-trigger' '---' 'Follow the **session-miner** skill.' '' 'profile=papercuts' \
  >"$pos_routines/fixture-miner-trigger.md"
PORTABLE_FLEET_ROUTINES_DIR="$pos_routines" \
  "$BIN" --offline north-star-portable-routine-fleet >"$PROOF_DIR/run.out"
report="$PROOF_DIR/north-star-portable-routine-fleet.md"
[ -f "$report" ] || fail "missing report"
head -1 "$report" | grep -qx 'PASS-OFFLINE' || fail "positive verdict is not PASS-OFFLINE"
grep -q 'registry-rotator triggers:' "$report" || fail "report omitted rotator triggers"
grep -q 'session-miner triggers:' "$report" || fail "report omitted miner triggers"
grep -q 'The harness did not open a shared LastDB home.' "$report" \
  || fail "report omitted the LastDB refusal"
grep -q 'The harness did not run a canary upgrade.' "$report" \
  || fail "report omitted the canary refusal"
grep -q 'PROOF_VERDICT=PASS-OFFLINE' "$PROOF_DIR/run.out" || fail "runner omitted the verdict"
if grep -q '\.lastdb\|\.folddb' "$report"; then
  fail "report names a primary LastDB home"
fi

# Cause removed: the bootstrap kit is incomplete.
bad_templates="$NEG_DIR/templates"
mkdir -p "$bad_templates"
cp "$ROOT/templates/routine-fleet/"*.md "$bad_templates/"
rm -f "$bad_templates/workspace-config.md"
export NORTH_STAR_PROOF_DIR="$NEG_DIR/missing-template"
mkdir -p "$NORTH_STAR_PROOF_DIR"
if PORTABLE_FLEET_TEMPLATE_DIR="$bad_templates" bash "$HARNESS" >"$NEG_DIR/missing.out"; then
  fail "a kit with no workspace-config passed"
fi
head -1 "$NORTH_STAR_PROOF_DIR/north-star-portable-routine-fleet.md" | grep -qx 'FAIL' \
  || fail "missing workspace-config did not write FAIL"

# Cause removed: the engine no longer forbids hard-coded project paths.
bad_skill="$NEG_DIR/rotator.md"
python3 - "$ROOT/skills/registry-rotator/SKILL.md" "$bad_skill" <<'PY'
import pathlib, sys
source, dest = sys.argv[1:]
text = pathlib.Path(source).read_text()
needle = "Never embed EdgeVector-specific paths"
if needle not in text:
    raise SystemExit("rotator needle missing from the real skill")
pathlib.Path(dest).write_text(text.replace(needle, "Copy project paths into this skill.", 1))
PY
export NORTH_STAR_PROOF_DIR="$NEG_DIR/bad-engine"
mkdir -p "$NORTH_STAR_PROOF_DIR"
if PORTABLE_FLEET_ROTATOR_SKILL="$bad_skill" bash "$HARNESS" >"$NEG_DIR/engine.out"; then
  fail "an engine that allows hard-coded paths passed"
fi
head -1 "$NORTH_STAR_PROOF_DIR/north-star-portable-routine-fleet.md" | grep -qx 'FAIL' \
  || fail "bad engine did not write FAIL"
grep -q 'Never embed EdgeVector-specific paths' \
  "$NORTH_STAR_PROOF_DIR/north-star-portable-routine-fleet.md" \
  || fail "bad engine report did not name the missing contract text"

# Cause removed: fewer than two registry-rotator triggers.
bad_routines="$NEG_DIR/routines"
mkdir -p "$bad_routines"
cp "$ROOT/routines/"*.md "$bad_routines/"
rm -f "$bad_routines/dogfood-rotate.md" "$bad_routines/owner-review-rotate.md"
export NORTH_STAR_PROOF_DIR="$NEG_DIR/bad-triggers"
mkdir -p "$NORTH_STAR_PROOF_DIR"
if PORTABLE_FLEET_ROUTINES_DIR="$bad_routines" bash "$HARNESS" >"$NEG_DIR/triggers.out"; then
  fail "fewer than two rotator triggers passed"
fi
head -1 "$NORTH_STAR_PROOF_DIR/north-star-portable-routine-fleet.md" | grep -qx 'FAIL' \
  || fail "missing triggers did not write FAIL"

# Cause removed: a routine that only MENTIONS profile= in a sentence is not a
# thin trigger. Keep one real trigger plus one mention-only routine.
mention_routines="$NEG_DIR/mention-routines"
mkdir -p "$mention_routines"
cp "$ROOT/routines/"*.md "$mention_routines/"
printf '%s\n' '---' 'name: fixture-mention-only' '---' 'Use the `session-miner` skill with `profile=friction-patterns` for detail.' \
  >"$mention_routines/fixture-mention-only.md"
export NORTH_STAR_PROOF_DIR="$NEG_DIR/mention-only"
mkdir -p "$NORTH_STAR_PROOF_DIR"
if PORTABLE_FLEET_ROUTINES_DIR="$mention_routines" bash "$HARNESS" >"$NEG_DIR/mention.out"; then
  fail "a profile= mention inside a sentence counted as a thin trigger"
fi
head -1 "$NORTH_STAR_PROOF_DIR/north-star-portable-routine-fleet.md" | grep -qx 'FAIL' \
  || fail "mention-only routines did not write FAIL"

# A primary LastDB path is refused before any read.
export NORTH_STAR_PROOF_DIR="$NEG_DIR/primary"
mkdir -p "$NORTH_STAR_PROOF_DIR"
primary_child="$HOME/.lastdb/portable-fleet-proof-refuse"
if PORTABLE_FLEET_TEMPLATE_DIR="$primary_child" bash "$HARNESS" >"$NEG_DIR/primary.out"; then
  fail "a primary LastDB template path passed"
fi
[ ! -e "$primary_child" ] || fail "the harness created a path under the primary LastDB home"
head -1 "$NORTH_STAR_PROOF_DIR/north-star-portable-routine-fleet.md" | grep -qx 'FAIL' \
  || fail "primary path did not write FAIL"

echo "PASS last-stack-north-star-proof-portable-routine-fleet"
