#!/usr/bin/env bash
# Proof: board-closeout-sweep uses a lightweight doing preview, then confirms
# the column against one native raw23 batch before it moves a card. `kanban list
# --column doing` can serve a stale BoardCards row for a card that already
# moved to done; the sweep must not demote or roll that card. An unavailable
# canonical key refuses the complete batch and causes zero writes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"
source "$ROOT/tests/fixtures/factory-closeout-dependencies.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export BOARD_CLOSEOUT_STATE_DIR="$tmp/state"

board="$tmp/board"
moves="$tmp/moves"
: >"$moves"

cat >"$board" <<'BOARD'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  guarded-snapshot)
    exec "${FACTORY_CLOSEOUT_FIXTURE_NATIVE:?}" --cards-file "$0.cards.json" "$@"
    ;;
  list)
    if [ -f "$0.preview.json" ]; then cat "$0.preview.json"; exit 0; fi
    case " $* " in
      *" --full-body "*)
        echo "unexpected full-body BoardCards read: $*" >&2
        exit 2
        ;;
    esac
    # Three deploy-parked rows the list reports in doing.
    cat <<'JSON'
[
  {
    "slug": "done-but-listed",
    "title": "done card still served in doing by list",
    "column": "doing",
    "position": "2",
    "assignee": "",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  },
  {
    "slug": "truly-doing-park",
    "title": "deploy park whose Card tip is doing",
    "column": "doing",
    "position": "3",
    "assignee": "",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  },
  {
    "slug": "show-fails-park",
    "title": "deploy park where show is unavailable",
    "column": "doing",
    "position": "4",
    "assignee": "",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  }
]
JSON
    ;;
  show)
    printf '%s\n' "$*" >>"${BOARD_CALLS:?}"
    slugs=""
    pos=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --json) shift ;;
        --slugs) slugs="$2"; shift 2 ;;
        --help|-h) echo "Options: --json --slugs"; exit 0 ;;
        *) pos="$1"; shift ;;
      esac
    done
    emit() {
      case "$1" in
        done-but-listed)
          printf '{"slug":"done-but-listed","column":"done","board":"default"}' ;;
        truly-doing-park)
          printf '{"slug":"truly-doing-park","column":"doing","board":"default"}' ;;
        *)
          return 1 ;;
      esac
    }
    if [ -n "$slugs" ]; then
      printf '['
      sep=""
      old_ifs="$IFS"
      IFS=','
      set -f
      # shellcheck disable=SC2086
      set -- $slugs
      set +f
      IFS="$old_ifs"
      for s in "$@"; do
        [ -n "$s" ] || continue
        if chunk="$(emit "$s")"; then
          printf '%s%s' "$sep" "$chunk"
          sep=","
        fi
      done
      printf ']\n'
      exit 0
    fi
    emit "$pos" && printf '\n' && exit 0
    echo "show unavailable" >&2
    exit 3
    ;;
  add|tag|set|mark)
    : ;;
  move)
    printf '%s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"${BOARD_MOVES:?}"
    ;;
  *)
    echo "unexpected: $*" >&2
    exit 2
    ;;
esac
BOARD
chmod +x "$board"

export BOARD_MOVES="$moves"
export BOARD_CALLS="$tmp/calls.log"
: >"$tmp/calls.log"

stack="$tmp/stack"
mkdir -p "$stack/bin"
cp "$sweep" "$stack/bin/last-stack-board-closeout-sweep"
fixture_closeout_native_dependencies "$stack" "$board"
fixture_closeout_prepare_native_cards "$board" --column done-but-listed=done --missing show-fails-park
fixture_closeout_select_native_preview "$board" done-but-listed,truly-doing-park
out="$("$stack/bin/last-stack-board-closeout-sweep" --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$out"

# A card whose Card tip is done must never be moved, whatever list says.
if grep -q '^done-but-listed ' "$moves" 2>/dev/null; then
  echo "FAIL: sweep moved a card whose show column is done:" >&2
  cat "$moves" >&2
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'stale-list-row:done-but-listed:done'; then
  echo "FAIL: expected stale-list-row flag for done-but-listed" >&2
  exit 1
fi

# A deploy park whose Card tip is doing is still demoted to backlog.
if ! grep -q '^truly-doing-park backlog' "$moves"; then
  echo "FAIL: expected truly-doing-park demoted to backlog:" >&2
  cat "$moves" >&2
  exit 1
fi

# Missing-only pass: refuse mutation on stale preview.
: >"$moves"
fixture_closeout_select_native_preview "$board" show-fails-park
out="$("$stack/bin/last-stack-board-closeout-sweep" --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$out"
if grep -q '^show-fails-park ' "$moves" 2>/dev/null; then
  echo "FAIL: sweep mutated show-fails-park despite read failure:" >&2
  cat "$moves" >&2
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'card-read-failed:show-fails-park'; then
  echo "FAIL: expected card-read-failed flag for show-fails-park" >&2
  exit 1
fi

# A mixed present/missing response must refuse the whole flat-array read.
: >"$moves"
fixture_closeout_select_native_preview "$board" done-but-listed,truly-doing-park,show-fails-park
mixed="$("$stack/bin/last-stack-board-closeout-sweep" --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$mixed"
[ ! -s "$moves" ] || { echo "FAIL: mixed missing batch caused a write" >&2; cat "$moves" >&2; exit 1; }
for key in done-but-listed truly-doing-park show-fails-park; do
  echo "$mixed" | grep -q "card-read-failed:$key" || { echo "FAIL: mixed missing batch did not refuse $key" >&2; exit 1; }
done

batch_n="$(grep -c '^guarded-snapshot --slugs-file ' "$tmp/calls.log" || true)"
[ "$batch_n" = 3 ] || {
  echo "FAIL: want 3 guarded-snapshot calls (one per pass), got $batch_n: $(cat "$tmp/calls.log")" >&2
  exit 1
}
if grep -q '^show ' "$tmp/calls.log"; then
  echo "FAIL: legacy show was used: $(cat "$tmp/calls.log")" >&2
  exit 1
fi

echo "ok last-stack-board-closeout-stale-list-row"
