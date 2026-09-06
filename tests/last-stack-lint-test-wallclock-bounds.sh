#!/usr/bin/env bash
# A shell test must not compare a measured wall clock against a bare literal.
#
# The shape: the test reads `date +%s` twice across a process boundary, and
# asserts the difference is under a number someone tuned on an idle laptop. The
# number then measures the CI HOST, and the test goes red on a loaded runner
# while every assertion that detects the real defect passes.
#
# Recorded four times on this fleet across three repos:
#   lastgit  papercut-lastgit-runcommand-timeout-test-bound-measures-the-runner (#500)
#   fkanban  papercut-fkanban-timeout-sensitive-tests-flake-under-host-load-20260905
#   last-stack tests/host-track-soak-starve-bound.sh   3001 >= 3000   (PR 19)
#   last-stack tests/last-stack-kanban-pickup-gate.sh  7s vs a 5 ceiling covering two 5s calls (PR 19)
#   last-stack tests/last-stack-lastdb-safe-upgrade-loom-only.sh  8s vs a literal 8
#
# papercut-last-stack-shell-test-wall-clock-bounds-measure-the-ci-host-20260906
# named this lint as the follow-up it did not ship: "a lint over tests/*.sh for
# `date +%s` differences compared against a literal, which is exactly the shape
# both of these had". The instance it could not see went red on Forge CI the
# same day and blocked an unrelated fix.
#
# A bound whose tightness adds no detection power adds only flake. Derive the
# ceiling from the constants the test itself configures, so changing a budget
# moves the bound. When a literal really is right, say why on the line:
#     # wallclock-bound-ok: <reason>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
violations=0

for f in tests/*.sh; do
  [ -f "$f" ] || continue
  # 1. Variables assigned from a DIFFERENCE of clock reads. A bare epoch read
  #    (`t0="$(date +%s)"`) is fine; only the delta gets compared to a ceiling.
  deltas="$(grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=.*date \+%s' "$f" \
            | grep -E '\-' \
            | sed -E 's/^[0-9]+:[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' \
            | sort -u || true)"
  [ -n "$deltas" ] || continue

  for v in $deltas; do
    # 2. ...compared against a BARE INTEGER with a numeric test operator.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      line_no="${hit%%:*}"
      text="${hit#*:}"
      # Explicit, reasoned opt-out on the line itself or anywhere in the
      # contiguous comment block directly above it. A justification worth
      # reading rarely fits on one line, and the first version of this check
      # looked only at the immediately preceding line — so a two-line reason
      # was reported as unjustified.
      block=""
      probe=$(( line_no - 1 ))
      while [ "$probe" -gt 0 ]; do
        pline="$(sed -n "${probe}p" "$f")"
        case "$pline" in
          *[!\ ]*)
            case "$(printf '%s' "$pline" | sed 's/^[[:space:]]*//')" in
              '#'*) block="$block$pline" ; probe=$(( probe - 1 )) ; continue ;;
            esac
            ;;
        esac
        break
      done
      case "$text$block" in *wallclock-bound-ok:*) continue ;; esac
      printf 'wallclock-bound: %s:%s compares measured elapsed `%s` against a literal\n' \
        "$f" "$line_no" "$v" >&2
      printf '  %s\n' "$(printf '%s' "$text" | sed 's/^[[:space:]]*//')" >&2
      violations=$(( violations + 1 ))
    done <<EOF
$(grep -nE "\\\$\{?$v\}?\"?[[:space:]]+-(lt|gt|le|ge)[[:space:]]+\"?[0-9]+\"?" "$f" || true)
EOF
  done
done

if [ "$violations" -gt 0 ]; then
  cat >&2 <<'MSG'

Derive the ceiling from the budgets the test configures, not from a number
observed on an idle host. If a literal is genuinely correct, justify it inline:
    # wallclock-bound-ok: <reason>
MSG
  echo "FAIL: $violations wall-clock bound(s) compared against a literal" >&2
  exit 1
fi

echo "ok last-stack-lint-test-wallclock-bounds: no measured elapsed compared to a literal"
