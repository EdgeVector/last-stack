#!/usr/bin/env bash
# Fixture test for bin/last-stack-kanban-deferral-release.
# Offline: fake kanban, brain and forge-api binaries; no live board is read.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/deferral-release.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/cards"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

brief='Repo: EdgeVector/fold\nBase: main\nKind: pr\n\n## GOAL\n\nDo the thing.\n\n## END STATE\n\nThe thing is done.\n'

# One JSON file per card; `list` concatenates the held ones for a column.
card() {
  # slug column block_status kind tags_json reason body
  cat >"$tmp/cards/$1.json" <<JSON
{"slug":"$1","column":"$2","block_status":"$3","kind":"$4","tags":$5,"block_reason":"$6","body":"$7"}
JSON
}
# The 2026-09-24 shape: the cause leads with "awaiting" and names papercuts.
card rel-papercut backlog deferred pr '[]' \
  'awaiting retry-path papercuts before a fresh loom execution opens (papercut-fixed-one); see STALE-PR REAP note — do not re-pickup until those clear' "$brief"
card keep-two backlog deferred pr '[]' \
  'awaiting papercuts (papercut-fixed-one, papercut-open-one)' "$brief"
# "Blocked on <slug>" names a card; done-card is done, so this releases.
card blocked-on backlog deferred pr '[]' \
  'Blocked on done-card-x-y, which merged; see note' "$brief"
card done-card-x-y done none pr '[]' '' "$brief"
# A papercut cited as history is not a release condition.
card incidental backlog needs_human pr '[]' \
  'needs a real cloud cutover; re-checked 6x (papercut-fixed-one). Clear once a canary exists, see card lastdb-other-card' "$brief"
card uncond backlog needs_human pr '[]' \
  'waiting on a Tom decision' "$brief"
card held-none backlog deferred pr '[]' \
  'superseded by slice-a, slice-b' "${brief}\\nRELEASE-WHEN: none\\n"
card body-mixed todo needs_human pr '[]' \
  'see body' "${brief}\\nRELEASE-WHEN: card:done-card, http://localhost:3300/EdgeVector/fold/pulls/12, after 2026-01-01\\n"
card pr-open backlog deferred pr '[]' \
  'see body' "${brief}\\nRELEASE-WHEN: EdgeVector/fold#13\\n"
card deploy-park backlog deferred pr '["awaiting-deploy"]' \
  'awaiting papercut-fixed-one' "$brief"
card bad-token backlog deferred pr '[]' \
  'see body' "${brief}\\nRELEASE-WHEN: when the moon is full\\n"
card done-card done none pr '[]' '' "$brief"
card free-card backlog none pr '[]' '' "$brief"

cat >"$tmp/bin/kanban" <<SH
#!/usr/bin/env bash
set -euo pipefail
cards="$tmp/cards"
log="$tmp/board.log"
case "\$1" in
  list)
    col="\$3"
    printf '{"cards":['
    sep=""
    for f in "\$cards"/*.json; do
      if jq -e --arg c "\$col" '.column == \$c' "\$f" >/dev/null; then
        printf '%s' "\$sep"; jq -c '.body = ""' "\$f"; sep=","
      fi
    done
    printf '],"truncated":false}\n'
    ;;
  show)
    [ -f "\$cards/\$2.json" ] || { echo "no card \$2" >&2; exit 1; }
    cat "\$cards/\$2.json"
    ;;
  pickup)
    printf '{"slug":"%s","ready":true,"write_guard":{"ok":true}}\n' "\$3"
    ;;
  set|mark|move|add|tag|rm)
    printf '%s\n' "\$*" >>"\$log"
    ;;
  *) echo "unexpected kanban \$*" >&2; exit 2 ;;
esac
SH

cat >"$tmp/bin/brain" <<'SH'
#!/usr/bin/env bash
case "$2" in
  papercut-fixed-one) echo fixed ;;
  papercut-open-one) echo open ;;
  *) echo "error: No papercut: $2" >&2; exit 1 ;;
esac
SH

cat >"$tmp/bin/forge-api" <<'SH'
#!/usr/bin/env bash
case "$1" in
  repos/EdgeVector/fold/pulls/12) echo '{"state":"closed","merged":true,"merge_commit_sha":"abcdef1234567890"}' ;;
  repos/EdgeVector/fold/pulls/13) echo '{"state":"open","merged":false}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/kanban" "$tmp/bin/brain" "$tmp/bin/forge-api"

tool=("$ROOT/bin/last-stack-kanban-deferral-release"
  --board-cli "$tmp/bin/kanban" --brain-cli "$tmp/bin/brain"
  --forge-api "$tmp/bin/forge-api" --now 2026-09-26T12:00:00Z)

# ── dry-run: classify, write nothing ───────────────────────────────────────
"${tool[@]}" --json >"$tmp/dry.json" 2>"$tmp/dry.err"
[ ! -f "$tmp/board.log" ] || fail "dry-run wrote to the board: $(cat "$tmp/board.log")"
grep -q 'mode=dry-run' "$tmp/dry.err" || fail "dry-run summary line missing: $(cat "$tmp/dry.err")"

slugs() { jq -r --arg k "$1" '[.[$k][].slug] | sort | join(",")' "$tmp/dry.json"; }
[ "$(slugs released)" = "blocked-on,body-mixed,rel-papercut" ] || fail "released=$(slugs released)"
[ "$(slugs kept)" = "keep-two,pr-open" ] || fail "kept=$(slugs kept)"
[ "$(slugs unconditioned)" = "incidental,uncond" ] || fail "unconditioned=$(slugs unconditioned)"
[ "$(slugs held)" = "held-none" ] || fail "held=$(slugs held)"
[ "$(slugs deploy_owned)" = "deploy-park" ] || fail "deploy_owned=$(slugs deploy_owned)"
[ "$(slugs malformed)" = "bad-token" ] || fail "malformed=$(slugs malformed)"
jq -e '.kept[] | select(.slug=="keep-two") | .open | join(" ") | test("papercut-open-one")' "$tmp/dry.json" >/dev/null \
  || fail "keep-two does not name its open papercut"
jq -e '.kept[] | select(.slug=="keep-two") | .met | join(" ") | test("papercut-fixed-one")' "$tmp/dry.json" >/dev/null \
  || fail "keep-two does not name its met papercut"

# ── apply: release only the two, move the backlog Kind:pr card to todo ────
"${tool[@]}" --apply >"$tmp/apply.out" 2>"$tmp/apply.err"
grep -q 'released=3 kept=2 unconditioned=2' "$tmp/apply.out" || fail "apply summary: $(cat "$tmp/apply.out")"
grep -qx 'set rel-papercut --block-status none' "$tmp/board.log" || fail "rel-papercut not cleared"
grep -qx 'set body-mixed --block-status none' "$tmp/board.log" || fail "body-mixed not cleared"
grep -q '^mark rel-papercut RELEASED .*papercut-fixed-one status=fixed' "$tmp/board.log" || fail "rel-papercut evidence mark missing"
grep -qx 'move rel-papercut todo' "$tmp/board.log" || fail "rel-papercut not moved to todo"
if grep -q '^move body-mixed' "$tmp/board.log"; then fail "body-mixed already in todo was moved"; fi
for s in keep-two uncond incidental held-none pr-open deploy-park bad-token done-card free-card; do
  if grep -Eq "^[a-z]+ $s( |\$)" "$tmp/board.log"; then fail "$s was touched: $(cat "$tmp/board.log")"; fi
done

# ── prompt wiring: the sweeper is called, and the reaper files its slices ──
grep -q 'bin/last-stack-kanban-deferral-release" --apply' "$ROOT/routines/groom-board.md" \
  || fail "groom-board does not run the deferral-release sweep"
reaper="$ROOT/routines/pr-reaper.md"
grep -q 'last-stack-kanban-file-pr' "$reaper" || fail "pr-reaper does not file slices via last-stack-kanban-file-pr"
grep -q 'RELEASE-WHEN: none' "$reaper" || fail "pr-reaper superseded card lacks RELEASE-WHEN: none"
grep -q 'At most \*\*4 slices\*\*' "$reaper" || fail "pr-reaper slice cap missing"
grep -q '^### RELEASE-WHEN' "$ROOT/skills/kanban/SKILL.md" || fail "kanban skill does not document RELEASE-WHEN"

printf 'ok: deferral-release releases only cards whose named conditions all hold\n'
