#!/usr/bin/env bash
# Contract: agent-facing prose must hand a detached `*.PURGE*` cache to
# bin/last-stack-purge-to-trash, never to a bare `rm -rf`.
#
# Ground truth: papercut-disk-reclaim-trash-permission-denied-20260925. The
# helper shipped on 2026-09-25 (4f4f20fbe) with its own CI fixture and then had
# ZERO callers: `grep -rn purge-to-trash` over the whole tree matched only the
# helper and its test. Both places that actually run the emergency purge --
# routines/disk-reclaim.md step 5 and skills/machine-hygiene/SKILL.md -- still
# told the agent to run `rm -rf <path>.PURGE`, which the managed execution
# policy rejects (the same rejection step 4b of that routine already documents).
# The agent improvised with /usr/bin/trash (NSCocoaErrorDomain 513) and
# `gio trash` (no ~/.local/share/Trash), both failed, and 6.5 GiB stayed
# detached under a `purge_continuing` report.
#
# So this guard is per-LINE, not per-file: naming the helper somewhere in a
# document does not excuse a bare `rm -rf` on a PURGE path further down it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
helper="$root/bin/last-stack-purge-to-trash"

fail() {
  printf 'purge-prose-uses-helper: %s\n' "$1" >&2
  exit 1
}

[ -x "$helper" ] || fail "missing or non-executable bin/last-stack-purge-to-trash"

# 1. No agent-facing prose may instruct a bare `rm -rf` on a `*.PURGE*` path.
#    The pattern requires the PURGE token to come AFTER `rm -rf` on the line, so
#    the step-5 sentence that PROHIBITS re-entering a large `rm -rf` (it names
#    `*.PURGE*` first) is correctly not a violation.
prose_files="$(
  cd "$root" && ls routines/*.md skills/*/SKILL.md instructions/*.md 2>/dev/null || true
)"
[ -n "$prose_files" ] || fail "found no agent-facing prose to scan"

violations="$(
  cd "$root" && printf '%s\n' "$prose_files" \
    | xargs grep -nE 'rm[[:space:]]+-[rRf]+[[:space:]][^`]*\.PURGE' 2>/dev/null || true
)"
if [ -n "$violations" ]; then
  printf '%s\n' "$violations" >&2
  fail "prose instructs a bare rm -rf on a .PURGE path; call bin/last-stack-purge-to-trash instead"
fi

# 2. The two documents that own the emergency purge must name the helper and its
#    exit-code contract, so an agent reading only that block knows what to run
#    and that exit 1 is a success.
for rel in routines/disk-reclaim.md skills/machine-hygiene/SKILL.md; do
  f="$root/$rel"
  [ -f "$f" ] || fail "missing $rel"
  grep -Fq 'last-stack-purge-to-trash' "$f" \
    || fail "$rel does not name bin/last-stack-purge-to-trash"
  grep -Fq 'fallback delete' "$f" \
    || fail "$rel does not state that exit 1 (fallback delete) also reclaimed the space"
done

# 3. The helper must accept the call shape the prose prescribes, and must not
#    leave the detached path behind when Trash is unavailable.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/purge-prose.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/cache.PURGE/sub"
: > "$scratch/cache.PURGE/sub/blob"

rc=0
PATH="/usr/bin:/bin" "$helper" --log-file "$scratch/purge.log" "$scratch/cache.PURGE" \
  >"$scratch/out" 2>"$scratch/err" || rc=$?
case "$rc" in
  0|1) ;;
  *) fail "helper exited $rc on the documented call shape; stderr: $(cat "$scratch/err")" ;;
esac
[ -d "$scratch/cache.PURGE" ] \
  && fail "helper exited $rc but left the detached path in place"
[ -s "$scratch/purge.log" ] || fail "helper wrote no --log-file entry"

echo "ok last-stack-purge-prose-uses-helper"
