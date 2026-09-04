#!/usr/bin/env bash
# The heal must land exactly the torn-verdict shape and nothing else.
#
# Torn verdict = the forge log recorded `ci_verdict_unconfirmed*` for the oid
# (CI was accepted as success) AND the durable row still reads `pending`. A
# pending row with no such line is a CI run still in flight; a `success` row
# needs no help; a ref that is not a fast-forward must never be pushed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-lastgit-stuck-merge-heal"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/stuck-merge-heal-test.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

TORN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
RUNNING=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
GREEN=cccccccccccccccccccccccccccccccccccccccc
MERGE_OID=dddddddddddddddddddddddddddddddddddddddd

cat > "$tmp/forge.log" <<LOG
unconfirmed $TORN ci-required: ci_verdict_unconfirmed_after_retry: ${TORN:0:12} ci-required was accepted as success but the status row still reads pending.
LOG

cat > "$tmp/lastgit" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$tmp/lastgit-calls"
case "\$1 \$2" in
  "cr list")
    printf 'cr-torn\topen\tx->main\ttorn verdict\n'
    printf 'cr-running\topen\ty->main\tci still running\n'
    printf 'cr-green\topen\tz->main\talready green\n'
    ;;
  "cr view")
    case "\$4" in
      cr-torn) oid=$TORN ;;
      cr-running) oid=$RUNNING ;;
      *) oid=$GREEN ;;
    esac
    printf 'head_oid\t%s\n' "\$oid"
    printf 'base_branch\tmain\n'
    printf 'auto_merge\ttrue\n'
    printf 'require_status\tci-required\n'
    if [ "\$4" = cr-torn ] && [ -f "$tmp/merged" ]; then
      printf 'state\tmerged\n'
      printf 'merge_oid\t$MERGE_OID\n'
    else
      printf 'state\topen\n'
      printf 'merge_oid\t\n'
    fi
    ;;
  "ci status")
    case "\$3" in
      $GREEN) printf 'success\tci-required\n' ;;
      *) printf 'pending\tci-required\n' ;;
    esac
    ;;
  "cr merge") touch "$tmp/merged" ;;
  "ref "*|"ref") printf '%s\trefs/heads/main\tpoint\n' "\$(cat "$tmp/refhead")" ;;
esac
exit 0
STUB
chmod +x "$tmp/lastgit"
echo 0000000000000000000000000000000000000000 > "$tmp/refhead"

# git stub: `init` makes the dir, `merge-base --is-ancestor` answers from a
# fixture file, `push` records the refspec it was handed.
cat > "$tmp/git" <<STUB
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *" init "*) mkdir -p "\${@: -1}"; exit 0 ;;
  *merge-base*) exit "\$(cat "$tmp/ancestor")" ;;
  *push*) echo "\$args" >> "$tmp/git-push"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$tmp/git"
echo 0 > "$tmp/ancestor"

export LASTGIT_FORGE_LOG="$tmp/forge.log"
: > "$tmp/lastgit-calls"; : > "$tmp/git-push"

# --- dry run must change nothing -------------------------------------------
PATH="$tmp:$PATH" bash "$bin" --repos demo > "$tmp/dry" 2>&1 \
  || { echo "FAIL: dry run errored"; cat "$tmp/dry"; exit 1; }
grep -q "cr merge" "$tmp/lastgit-calls" \
  && { echo "FAIL: dry run merged a CR"; cat "$tmp/lastgit-calls"; exit 1; }
grep -q "would admin-merge demo:cr-torn" "$tmp/dry" \
  || { echo "FAIL: dry run did not name the torn CR"; cat "$tmp/dry"; exit 1; }

# --- apply: merge the torn one, leave the other two alone -------------------
: > "$tmp/lastgit-calls"
PATH="$tmp:$PATH" bash "$bin" --repos demo --apply > "$tmp/out" 2>&1 \
  || { echo "FAIL: apply errored"; cat "$tmp/out"; exit 1; }

grep -q "cr merge demo cr-torn --admin" "$tmp/lastgit-calls" \
  || { echo "FAIL: torn CR was not admin-merged"; cat "$tmp/lastgit-calls"; exit 1; }
grep -q "cr merge demo cr-running" "$tmp/lastgit-calls" \
  && { echo "FAIL: merged a CR whose CI is still running"; exit 1; }
grep -q "cr merge demo cr-green" "$tmp/lastgit-calls" \
  && { echo "FAIL: merged a CR that needed no help"; exit 1; }
grep -q "$MERGE_OID:refs/heads/main" "$tmp/git-push" \
  || { echo "FAIL: unlanded ref was not fast-forwarded"; cat "$tmp/git-push"; exit 1; }
grep -q "merged=1" "$tmp/out" \
  || { echo "FAIL: summary should report merged=1"; cat "$tmp/out"; exit 1; }

# --- a non-fast-forward must be refused, never forced -----------------------
rm -f "$tmp/merged"; : > "$tmp/git-push"; echo 1 > "$tmp/ancestor"
PATH="$tmp:$PATH" bash "$bin" --repos demo --apply > "$tmp/nff" 2>&1 \
  || { echo "FAIL: non-ff run errored"; cat "$tmp/nff"; exit 1; }
[ -s "$tmp/git-push" ] \
  && { echo "FAIL: pushed a non-fast-forward"; cat "$tmp/git-push"; exit 1; }
grep -q "REFUSED" "$tmp/nff" \
  || { echo "FAIL: non-fast-forward was not refused out loud"; cat "$tmp/nff"; exit 1; }

# --- a pending row with no accepted-as-success line is left alone -----------
rm -f "$tmp/merged"; : > "$tmp/forge.log"; : > "$tmp/lastgit-calls"
PATH="$tmp:$PATH" bash "$bin" --repos demo --apply > "$tmp/noev" 2>&1 \
  || { echo "FAIL: no-evidence run errored"; cat "$tmp/noev"; exit 1; }
grep -q "cr merge" "$tmp/lastgit-calls" \
  && { echo "FAIL: merged without an accepted-as-success line"; exit 1; }
grep -q "merged=0" "$tmp/noev" \
  || { echo "FAIL: summary should report merged=0"; cat "$tmp/noev"; exit 1; }

echo "PASS: last-stack-lastgit-stuck-merge-heal"
