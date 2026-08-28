#!/usr/bin/env bash
# The org-cloud offline proof must run from a packed artifact tree that has
# no tests/ directory. The fixture lives under harness/, which artifacts.json
# already packs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/org-cloud-offline-artifact.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pack="$tmp/packed"
mkdir -p "$pack"

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  src="$ROOT/$rel"
  dest="$pack/$rel"
  if [ -d "$src" ]; then
    mkdir -p "$dest"
    cp -R "$src"/. "$dest"/
  elif [ -f "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
  else
    fail "source tree missing packed path $rel"
  fi
done < <(jq -r '.artifacts[] | select(.app == "last-stack") | .paths[]' "$ROOT/.lastgit/artifacts.json")

[ ! -e "$pack/tests" ] || fail "packed tree unexpectedly contains tests/"
[ -f "$pack/harness/north-star/org-cloud-membership/offline-fixture.sh" ] ||
  fail "packed tree missing harness offline fixture"
[ -x "$pack/bin/last-stack-org-cloud-membership-dogfood" ] ||
  fail "packed tree missing live dogfood binary"
if grep -n 'tests/last-stack-org-cloud-membership-dogfood' \
  "$pack/harness/north-star/org-cloud-membership/run.sh"; then
  fail "packed run.sh still points at tests/"
fi

chmod +x "$pack/bin/"* "$pack/harness/north-star/org-cloud-membership/"*.sh
bash -n "$pack/harness/north-star/org-cloud-membership/run.sh"
bash -n "$pack/harness/north-star/org-cloud-membership/offline-fixture.sh"

proof_dir="$tmp/proofs"
mkdir -p "$proof_dir"
export NORTH_STAR_PROOF_DIR="$proof_dir"
export NORTH_STAR_PROOF_MODE=offline
set +e
"$pack/bin/last-stack-north-star-proof" --offline north-star-org-cloud-principal-membership \
  >"$tmp/stdout" 2>"$tmp/stderr"
proof_rc=$?
set -e
if grep -q 'No such file or directory' "$tmp/stderr" "$tmp/stdout"; then
  fail "packed offline proof reported a missing file"
fi
[ "$proof_rc" -eq 0 ] || fail "packed offline proof exited $proof_rc"
report="$proof_dir/north-star-org-cloud-principal-membership.md"
[ -f "$report" ] || fail "packed offline proof wrote no report"
head -n 1 "$report" | grep -qE '^PASS' || fail "packed proof first line is not PASS"

printf 'ok: org-cloud offline fixture exists in packed artifact tree\n'
