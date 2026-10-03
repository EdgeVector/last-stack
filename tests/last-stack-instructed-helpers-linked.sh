#!/usr/bin/env bash
# Every bin/ helper that the managed instruction blocks tell an agent to RUN
# must have a PATH link in config/host-track/apps.json.
#
# Why this exists (measured 2026-10-03). host-track's links[] is a LITERAL
# enumeration -- it does not glob bin/ -- and the failure when an entry is
# missing is silent: the file installs under the artifact root, no symlink
# appears in ~/.local/bin, and ~/.last-stack/bin is NOT on PATH. So the helper
# exists, is current, and the bare name does not resolve.
#
# bin/last-stack-mutation-probe shipped at 2026-10-03T03:00Z together with
# instructions/mutation-probe.md, which the setup step installs into
# ~/.claude/CLAUDE.md. That block tells every agent on this host, as a fenced
# command, to run `last-stack-mutation-probe --name ... --patch ... --test ...`
# before trusting any guard it writes -- and `command -v` answered
# "not found" for 11 hours while the rule was live. The same hole held
# bin/last-stack-locate-file, which instructions/bin-authoring.md prescribes as
# the bounded replacement for an unbounded walk.
#
# Scope is deliberately narrow: a helper counts only when it appears in COMMAND
# POSITION inside a fenced block. A prose mention does not (that is why
# last-stack-routine-shell-lint, described in prose as the hook that checks a
# command and never run by hand, is correctly absent from links[]). Measured
# when this test was written: the loose "named anywhere in instructions/*.md"
# reading found 14 candidates and 4 findings, two of which were prose; the
# fenced command-position reading found 3 candidates and 2 findings, both real.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APPS="$ROOT/config/host-track/apps.json"
fail=0

[ -f "$APPS" ] || { echo "FAIL instructed-helpers-linked: no $APPS" >&2; exit 1; }
[ -d "$ROOT/instructions" ] || { echo "FAIL instructed-helpers-linked: no instructions/" >&2; exit 1; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/instructed-helpers-linked.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

jq -r '.. | objects | select(.app=="last-stack") | .links[]?.source
       | select(startswith("bin/")) | ltrimstr("bin/")' "$APPS" \
  | sort -u >"$tmp/linked.txt"
[ -s "$tmp/linked.txt" ] || { echo "FAIL instructed-helpers-linked: read no links for app=last-stack" >&2; exit 1; }

# Command position: line start, or after a pipe/&&/;/( or inside $( ).
: >"$tmp/named.txt"
for md in "$ROOT"/instructions/*.md; do
  [ -f "$md" ] || continue
  awk -v f="$(basename "$md")" '
    /^[[:space:]]*```/ { infence = !infence; next }
    !infence { next }
    {
      line = $0
      while (match(line, /(^|[|&;(]|\$\()[[:space:]]*last-stack-[a-z0-9-]+/)) {
        tok = substr(line, RSTART, RLENGTH)
        sub(/^.*[[:space:]]/, "", tok); sub(/^[|&;($]+/, "", tok)
        if (tok ~ /^last-stack-[a-z0-9-]+$/) print tok "\t" f ":" NR
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$md" >>"$tmp/named.txt"
done

sort -u "$tmp/named.txt" -o "$tmp/named.txt"
checked=0
while IFS=$'\t' read -r cmd where; do
  [ -n "$cmd" ] || continue
  [ -f "$ROOT/bin/$cmd" ] || continue   # not a helper of this repo
  checked=$((checked + 1))
  if ! grep -qx "$cmd" "$tmp/linked.txt"; then
    echo "FAIL instructed-helpers-linked: instructions/$where prescribes '$cmd' as a command," >&2
    echo "  bin/$cmd exists, and config/host-track/apps.json has NO links[] entry for it." >&2
    echo "  Without one the bare name does not resolve: ~/.last-stack/bin is not on PATH." >&2
    echo "  Add: {\"source\": \"bin/$cmd\", \"target\": \"\$HOME/.local/bin/$cmd\"}" >&2
    fail=1
  fi
done <"$tmp/named.txt"

# A zero-candidate run would pass vacuously and the guard would be dead. The
# two helpers above are prescribed in fenced command position today, so hold a
# floor: if this trips, the awk scanner stopped matching, not the repo.
if [ "$checked" -lt 2 ]; then
  echo "FAIL instructed-helpers-linked: scanned only $checked prescribed helper(s)." >&2
  echo "  Expected at least 2 (mutation-probe, locate-file). The scanner is broken, not the repo." >&2
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "PASS last-stack-instructed-helpers-linked (prescribed helpers checked=$checked)"
