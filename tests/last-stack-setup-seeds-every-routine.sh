#!/usr/bin/env bash
# setup must invoke every bin/last-stack-*-routine registry seeder.
#
# Each of those scripts is a seed-if-missing installer for one routines
# registry entry, and setup is the only caller. The block used to be a
# hand-written list of if-blocks, so a seeder added later was simply never
# run: bin/last-stack-lastdb-canary-build-main-routine landed 2026-09-03 and
# no host ever registered lastdb-canary-build-main. Nothing then built a
# canary stage for fold main, and lastdb-local-smoke-test resolved a stale
# binary with sha_drift=true on every run for days
# (papercut-no-registered-routine-produces-a-lastdb-canary-candidate-20260903).
#
# This test fails if setup stops reaching any seeder, whether the loop is
# narrowed or an explicit list comes back missing an entry.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
cd "$ROOT"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-setup-seeds.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

seeders=()
for f in bin/last-stack-*-routine; do
  [ -f "$f" ] || continue
  seeders+=("$(basename "$f")")
done

if [ "${#seeders[@]}" -eq 0 ]; then
  echo "FAIL: no bin/last-stack-*-routine seeders found" >&2
  exit 1
fi

# Drive the real seeder block with stub seeders, so the assertion is about
# what setup EXECUTES, not about text that happens to appear in the file.
stub_bin="$tmp/bin"
mkdir -p "$stub_bin"
for name in "${seeders[@]}"; do
  cat > "$stub_bin/$name" <<STUB
#!/usr/bin/env bash
echo "$name" >> "$tmp/called.txt"
STUB
  chmod +x "$stub_bin/$name"
done

# Extract just the seeder block and run it against the stub directory. The
# block is delimited by its own comment header and the next section comment.
awk '
  /^# Seed missing registry TOMLs only\./ { inblock = 1 }
  /^# Zero-LLM self-upgrade healer/ { inblock = 0 }
  inblock { print }
' setup > "$tmp/block.sh"

if [ ! -s "$tmp/block.sh" ]; then
  echo "FAIL: could not locate the seeder block in setup" >&2
  exit 1
fi

: > "$tmp/called.txt"
SOURCE_ROOT="$tmp" bash "$tmp/block.sh" >/dev/null 2>&1

missing=()
for name in "${seeders[@]}"; do
  grep -qxF "$name" "$tmp/called.txt" || missing+=("$name")
done

if [ "${#missing[@]}" -ne 0 ]; then
  echo "FAIL: setup never invokes these registry seeders:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo "Every bin/last-stack-*-routine seeder must run from setup." >&2
  exit 1
fi

# The seeder that started this: name it explicitly so a future narrowing of
# the glob cannot quietly drop the canary producer again.
grep -qxF 'last-stack-lastdb-canary-build-main-routine' "$tmp/called.txt" || {
  echo "FAIL: setup does not seed lastdb-canary-build-main" >&2
  exit 1
}

echo "PASS: setup invokes all ${#seeders[@]} registry seeders"
