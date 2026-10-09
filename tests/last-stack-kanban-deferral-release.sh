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
  'see body' "${brief}\\nRELEASE-WHEN: EdgeVector/fold#13, https://github.com/EdgeVector/fold/pull/14\\n"
card gh-merged backlog deferred pr '[]' \
  'see body' "${brief}\\nRELEASE-WHEN: https://github.com/EdgeVector/fold/pull/14\\n"
card deploy-park backlog deferred pr '["awaiting-deploy"]' \
  'awaiting papercut-fixed-one' "$brief"
card bad-token backlog deferred pr '[]' \
  'see body' "${brief}\\nRELEASE-WHEN: when the moon is full\\n"
card done-card done none pr '[]' '' "$brief"
card free-card backlog none pr '[]' '' "$brief"

cat >"$tmp/bin/kanban" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
cards = root / 'cards'
args = sys.argv[1:]
with (root / 'calls.log').open('a') as stream:
    stream.write(' '.join(args) + '\n')
verb = args[0]
if verb == 'list':
    column = args[args.index('--column') + 1]
    records = []
    for path in sorted(cards.glob('*.json')):
        card = json.loads(path.read_text())
        if card['column'] == column:
            records.append({**card, 'body': ''})
    if column == 'backlog' and (root / 'inject-missing-preview').exists():
        records.append({'slug': 'gone-held', 'column': 'backlog', 'block_status': 'deferred',
                        'kind': 'pr', 'tags': [], 'block_reason': 'awaiting papercut-fixed-one', 'body': ''})
    print(json.dumps({'cards': records, 'truncated': False}))
elif verb == 'guarded-snapshot':
    assert len(args) == 4 and args[1] == '--slugs-file' and args[3] == '--json', args
    keys = json.loads(Path(args[2]).read_text())
    assert isinstance(keys, list) and len(keys) == len(set(keys))
    schema = 'a' * 64
    scalars = ('slug', 'title', 'body', 'board', 'column', 'position', 'assignee',
               'created_at', 'created_by', 'updated_at', 'db', 'repo', 'base', 'kind',
               'block_status', 'block_reason', 'north_star', 'milestone', 'pr_url', 'branch')
    items = []
    for key in keys:
        path = cards / (key + '.json')
        if not path.exists():
            items.append({'slug': key, 'missing': True})
            continue
        stored = json.loads(path.read_text())
        fields = {name: stored.get(name, '') for name in scalars}
        fields.update({name: stored.get(name, []) for name in ('tags', 'deps', 'surfaces')})
        fields['position'] = stored.get('position', '0')
        snapshot = json.dumps({'version': 1, 'schema_hash': schema, 'fields': fields},
                              sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n'
        items.append({'slug': key, 'snapshot_json': snapshot,
                      'snapshot_sha256': hashlib.sha256(snapshot.encode()).hexdigest()})
    print(json.dumps({'version': 1, 'schema_hash': schema, 'items': items}))
elif verb == 'show':
    assert len(args) == 3 and args[2] == '--json' and not args[1].startswith('--'), args
    path = cards / (args[1] + '.json')
    if not path.exists():
        print('no card ' + args[1], file=sys.stderr)
        sys.exit(1)
    print(path.read_text(), end='')
elif verb == 'pickup':
    print(json.dumps({'slug': args[2], 'ready': True, 'write_guard': {'ok': True}}))
elif verb in ('set', 'mark', 'move', 'add', 'tag', 'rm'):
    with (root / 'board.log').open('a') as stream:
        stream.write(' '.join(args) + '\n')
else:
    print('unexpected kanban ' + ' '.join(args), file=sys.stderr)
    sys.exit(2)
PY

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
# GitHub is the default venue: `owner/repo#N` and github.com URLs read through gh.
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = "pr view" ] && [ "$4" = "-R" ] || exit 2
case "$3 $5" in
  "14 EdgeVector/fold") echo '{"state":"MERGED","mergedAt":"2026-09-30T00:00:00Z","mergeCommit":{"oid":"0123456789abcdef"}}' ;;
  "13 EdgeVector/fold") echo '{"state":"OPEN","mergedAt":null,"mergeCommit":null}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/kanban" "$tmp/bin/brain" "$tmp/bin/forge-api" "$tmp/bin/gh"

tool=("$ROOT/bin/last-stack-kanban-deferral-release"
  --board-cli "$tmp/bin/kanban" --brain-cli "$tmp/bin/brain"
  --forge-api "$tmp/bin/forge-api" --gh "$tmp/bin/gh" --now 2026-09-26T12:00:00Z)

# ── dry-run: classify, write nothing ───────────────────────────────────────
"${tool[@]}" --json >"$tmp/dry.json" 2>"$tmp/dry.err"
[ ! -f "$tmp/board.log" ] || fail "dry-run wrote to the board: $(cat "$tmp/board.log")"
grep -q 'mode=dry-run' "$tmp/dry.err" || fail "dry-run summary line missing: $(cat "$tmp/dry.err")"

slugs() { jq -r --arg k "$1" '[.[$k][].slug] | sort | join(",")' "$tmp/dry.json"; }
[ "$(slugs released)" = "blocked-on,body-mixed,gh-merged,rel-papercut" ] || fail "released=$(slugs released)"
[ "$(slugs kept)" = "keep-two,pr-open" ] || fail "kept=$(slugs kept)"
[ "$(slugs unconditioned)" = "incidental,uncond" ] || fail "unconditioned=$(slugs unconditioned)"
[ "$(slugs held)" = "held-none" ] || fail "held=$(slugs held)"
[ "$(slugs deploy_owned)" = "deploy-park" ] || fail "deploy_owned=$(slugs deploy_owned)"
[ "$(slugs malformed)" = "bad-token" ] || fail "malformed=$(slugs malformed)"
[ "$(slugs errors)" = "" ] || fail "errors=$(slugs errors)"
batch_n="$(grep -c '^guarded-snapshot --slugs-file ' "$tmp/calls.log" || true)"
[ "$batch_n" = 1 ] || fail "want 1 public guarded-snapshot batch, got $batch_n: $(cat "$tmp/calls.log")"
if grep -q '^show --slugs ' "$tmp/calls.log"; then fail "used the retired batch contract"; fi
# Held candidates must not be point-read. card:done-card* shows are RELEASE-WHEN checks.
for s in bad-token blocked-on gh-merged held-none incidental keep-two pr-open rel-papercut uncond gone-held body-mixed deploy-park; do
  if grep -E "^show $s( |$)" "$tmp/calls.log" >/dev/null; then
    fail "held slug $s was point-read: $(grep -E '^show ' "$tmp/calls.log")"
  fi
done
: >"$tmp/calls.log"
jq -e '.kept[] | select(.slug=="keep-two") | .open | join(" ") | test("papercut-open-one")' "$tmp/dry.json" >/dev/null \
  || fail "keep-two does not name its open papercut"
jq -e '.kept[] | select(.slug=="keep-two") | .met | join(" ") | test("papercut-fixed-one")' "$tmp/dry.json" >/dev/null \
  || fail "keep-two does not name its met papercut"

# ── explicit canonical miss: no partial authority and no writes ──────────
# The public flat reader refuses the whole batch when one exact key is missing.
# Keep this negative separate from the complete classification/apply fixtures.
: >"$tmp/inject-missing-preview"
set +e
"${tool[@]}" --apply --json >"$tmp/missing.json" 2>"$tmp/missing.err"
missing_rc=$?
set -e
[ ! -f "$tmp/board.log" ] || fail "missing canonical batch wrote to the board"
[ "$missing_rc" = 1 ] || fail "missing canonical must make the batch unavailable: rc=$missing_rc"
jq -e '.released == [] and .kept == [] and (.errors | length) == 11 and
       ([.errors[].slug] | index("gone-held")) != null and
       ([.errors[].reason] | unique) == ["show-failed"]' "$tmp/missing.json" >/dev/null \
  || fail "missing canonical must leave all 11 selected Cards unavailable"
grep -q 'mode=apply.*released=0 kept=0' "$tmp/missing.err" \
  || fail "missing canonical summary must report no releases"
rm -f "$tmp/inject-missing-preview"
: >"$tmp/calls.log"

# ── apply: release only the four accepted Cards ──────────────────────────
"${tool[@]}" --apply >"$tmp/apply.out" 2>"$tmp/apply.err"
grep -q 'released=4 kept=2 unconditioned=2' "$tmp/apply.out" || fail "apply summary: $(cat "$tmp/apply.out")"
grep -qx 'set rel-papercut --block-status none' "$tmp/board.log" || fail "rel-papercut not cleared"
grep -qx 'set body-mixed --block-status none' "$tmp/board.log" || fail "body-mixed not cleared"
grep -q '^mark rel-papercut RELEASED .*papercut-fixed-one status=fixed' "$tmp/board.log" || fail "rel-papercut evidence mark missing"
grep -qx 'move rel-papercut todo' "$tmp/board.log" || fail "rel-papercut not moved to todo"
if grep -q '^move body-mixed' "$tmp/board.log"; then fail "body-mixed already in todo was moved"; fi
for s in keep-two uncond incidental held-none pr-open deploy-park bad-token done-card free-card gone-held; do
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
