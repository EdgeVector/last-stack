#!/usr/bin/env bash
# The harness folder IS the North Star proof registry.
#
# Guards two defects that both let a North Star complete without a proof:
#   1. hand-maintained slug lists drifting from harness/north-star/*/
#      (brain papercut-north-star-proof-runner-hardcoded-slug-registry)
#   2. the runner dying when invoked through a PATH symlink
#      (brain papercut-north-star-proof-runner-broken-through-path-symlink)
#
# Fault injection is part of the test, not an exercise for the reader: a
# registry check that passes against a broken registry is the same defect
# wearing the test's clothes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns-proof-registry-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-proof-registry: $*" >&2
  exit 1
}

# --- 1. every harness on disk declares its own slug -------------------------
#
# Enumerated from the filesystem, never from a list in this file — a test that
# iterates its own copy of the registry cannot detect the drift it exists for.
undeclared=""
for script in "$ROOT"/harness/north-star/*/run.sh; do
  [ -f "$script" ] || continue
  if ! grep -q '^#[[:space:]]*north-star-slug:[[:space:]]*north-star-' "$script"; then
    undeclared="$undeclared $(basename "$(dirname "$script")")"
  fi
done
[ -z "$undeclared" ] || fail "harnesses declare no slug:$undeclared"

# --- 2. --list covers every harness folder, sorted and unique ---------------
listed="$(bash "$RUNNER" --list)"
listed_count="$(printf '%s\n' "$listed" | grep -c .)"
folder_count="$(find "$ROOT/harness/north-star" -mindepth 2 -maxdepth 2 -name run.sh | grep -c .)"
[ "$listed_count" -eq "$folder_count" ] ||
  fail "--list has $listed_count slugs, harness/north-star has $folder_count run.sh files"

sorted="$(printf '%s\n' "$listed" | LC_ALL=C sort)"
[ "$listed" = "$sorted" ] || fail "--list is not sorted"

unique_count="$(printf '%s\n' "$listed" | LC_ALL=C sort -u | grep -c .)"
[ "$unique_count" -eq "$listed_count" ] || fail "--list contains duplicate slugs"

# The two slugs whose absence caused the incidents this test exists for: one
# was never registered at all, one hit the gap on 2026-08-06.
for required in north-star-revenant-watch north-star-app-ops-latency north-star-lastdb-ideal-storage-shape; do
  printf '%s\n' "$listed" | grep -qx "$required" ||
    fail "--list is missing $required"
done

# --- 3. the runner works through symlinks (the PATH regression) -------------
mkdir -p "$WORK/bin-a" "$WORK/bin-b"
ln -s "$RUNNER" "$WORK/bin-a/nsp"
ln -s "$WORK/bin-a/nsp" "$WORK/bin-b/nsp"

via_symlink="$(bash "$WORK/bin-a/nsp" --list)"
[ "$via_symlink" = "$listed" ] || fail "--list through a symlink differs from the direct invocation"

via_nested="$(bash "$WORK/bin-b/nsp" --list)"
[ "$via_nested" = "$listed" ] || fail "--list through a symlink-to-a-symlink differs"

# --- 4. fault injection on a synthetic tree --------------------------------
#
# A miniature ROOT so a deliberately broken registry can be observed without
# touching the repo's real harnesses.
synth="$WORK/synth"
mkdir -p "$synth/bin" "$synth/harness/north-star/demo-a" "$synth/harness/north-star/demo-b"
cp "$RUNNER" "$synth/bin/last-stack-north-star-proof"
cp "$ROOT/harness/north-star/common.sh" "$synth/harness/north-star/common.sh"

write_harness() {
  printf '#!/usr/bin/env bash\n# north-star-slug: %s\nexit 0\n' "$2" >"$synth/harness/north-star/$1/run.sh"
}
write_harness demo-a north-star-demo-a
write_harness demo-b north-star-demo-b

synth_list="$(bash "$synth/bin/last-stack-north-star-proof" --list)"
[ "$synth_list" = "north-star-demo-a
north-star-demo-b" ] || fail "synthetic tree did not discover both demo harnesses (got: $synth_list)"

# 4a. a harness that declares no slug is a loud failure naming the folder
printf '#!/usr/bin/env bash\nexit 0\n' >"$synth/harness/north-star/demo-b/run.sh"
if out="$(bash "$synth/bin/last-stack-north-star-proof" --list 2>&1)"; then
  fail "fault injection did not fire: an undeclared harness still listed cleanly"
fi
printf '%s' "$out" | grep -q 'demo-b' ||
  fail "undeclared-harness error does not name the offending folder: $out"

# 4b. two harnesses claiming one slug is a loud failure naming both
write_harness demo-b north-star-demo-a
if out="$(bash "$synth/bin/last-stack-north-star-proof" --list 2>&1)"; then
  fail "fault injection did not fire: a duplicate slug still listed cleanly"
fi
printf '%s' "$out" | grep -q 'demo-a' && printf '%s' "$out" | grep -q 'demo-b' ||
  fail "duplicate-slug error does not name both folders: $out"

# 4c. an unknown slug still fails, and now says what it does know
write_harness demo-b north-star-demo-b
if bash "$synth/bin/last-stack-north-star-proof" north-star-does-not-exist >/dev/null 2>&1; then
  fail "an unknown slug did not fail"
fi

echo "PASS last-stack-north-star-proof-registry"
