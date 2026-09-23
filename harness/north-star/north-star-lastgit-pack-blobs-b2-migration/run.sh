#!/usr/bin/env bash
# north-star-slug: north-star-lastgit-pack-blobs-b2-migration
# Offline terminal proof for LastGit pack blobs on the B2 file plane.
# Does not open a LastDB home. Does not start a B2 cutover.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastgit-pack-blobs-b2-migration
MODE="$(ns_mode)"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
CHECK="$HERE/check_contract.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pack-blobs-b2-proof.XXXXXX")"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

finish() {
  local verdict="$1" body="$2"
  if [ "$verdict" = FAIL ]; then
    ns_write_report "$SLUG" FAIL "$body" || true
    exit 1
  fi
  ns_write_report "$SLUG" "$verdict" "$body"
  exit 0
}

case "$MODE" in
  live|offline) ;;
  *)
    finish FAIL "The proof mode is invalid: $MODE."
    ;;
esac

if [ -n "${LASTGIT_PACK_BLOBS_B2_ALLOW_CUTOVER:-}" ]; then
  finish FAIL "This harness does not start a B2 cutover. Remove LASTGIT_PACK_BLOBS_B2_ALLOW_CUTOVER."
fi

canonical_path() {
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

refuse_primary() {
  local candidate="$1" canon root
  [ -n "$candidate" ] || return 0
  canon="$(canonical_path "$candidate")" || finish FAIL "The harness could not resolve the path."
  for root in "$HOME/.lastdb" "$HOME/.folddb"; do
    [ -e "$root" ] || [ -L "$root" ] || continue
    root="$(canonical_path "$root")" || finish FAIL "The harness could not resolve the primary home."
    case "$canon" in
      "$root"|"$root"/*)
        finish FAIL "The harness refuses a LastDB home path."
        ;;
    esac
  done
}

REPO="${LASTGIT_REPO:-}"
if [ -z "$REPO" ]; then
  REPO="$(ns_repo_path lastgit)"
fi
refuse_primary "$REPO"

for rel in \
  src/pack-blob-pointer.ts \
  src/client.ts \
  src/cli.ts \
  src/forge-resilience.ts
do
  [ -f "$REPO/$rel" ] || finish FAIL "The LastGit source is absent: $rel."
  refuse_primary "$REPO/$rel"
done

EVIDENCE="${LASTGIT_PACK_BLOBS_B2_PROOF_EVIDENCE_FILE:-}"
if [ -n "$EVIDENCE" ]; then
  refuse_primary "$EVIDENCE"
  [ -f "$EVIDENCE" ] || finish FAIL "The evidence file is absent."
fi

bun_line="Bun pack-file contract: skipped"
case "${LASTGIT_PACK_BLOBS_B2_RUN_BUN:-auto}" in
  0|false|no) ;;
  1|true|yes|auto)
    if [ "${LASTGIT_PACK_BLOBS_B2_RUN_BUN:-auto}" = auto ] &&
      { [ ! -f "$REPO/test/pack-file-blob.test.ts" ] ||
        [ ! -d "$REPO/node_modules" ] ||
        ! command -v bun >/dev/null 2>&1; }; then
      :
    else
      [ -f "$REPO/test/pack-file-blob.test.ts" ] || finish FAIL "The pack-file contract test is absent."
      [ -d "$REPO/node_modules" ] || finish FAIL "The pack-file contract test needs node_modules."
      command -v bun >/dev/null 2>&1 || finish FAIL "The pack-file contract test needs bun."
      mkdir -p "$TMP/cas"
      set +e
      (
        cd "$REPO" || exit 97
        env -u LASTGIT_SOCKET -u LASTDB_HOME -u FOLDDB_HOME -u LASTDB_SOCKET \
          LASTGIT_PACK_CAS_DIR="$TMP/cas" \
          bun test test/pack-file-blob.test.ts
      ) >"$TMP/bun.out" 2>&1
      bun_rc=$?
      set -e
      if [ "$bun_rc" -eq 0 ]; then
        bun_line="Bun pack-file contract: hold"
      else
        bun_line="Bun pack-file contract: broken"
      fi
    fi
    ;;
  *)
    finish FAIL "LASTGIT_PACK_BLOBS_B2_RUN_BUN is invalid."
    ;;
esac

set +e
BODY="$(python3 "$CHECK" \
  "$REPO/src/pack-blob-pointer.ts" \
  "$REPO/src/client.ts" \
  "$REPO/src/cli.ts" \
  "$REPO/src/forge-resilience.ts" \
  "$EVIDENCE" \
  "$MODE" 2>"$TMP/check.err")"
RC=$?
set -e
if [ -s "$TMP/check.err" ]; then
  BODY="${BODY}

Checker error:
$(cat "$TMP/check.err")"
fi
BODY="${BODY}

${bun_line}
LastGit repo: ${REPO}"

if [ "$RC" -ne 0 ] || [ "$bun_line" = "Bun pack-file contract: broken" ]; then
  finish FAIL "$BODY"
fi

if [ "$MODE" = live ]; then
  finish PASS "$BODY"
fi
finish PASS-OFFLINE "$BODY"
