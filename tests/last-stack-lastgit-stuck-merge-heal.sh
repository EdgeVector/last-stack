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
SETTLED=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

cat > "$tmp/forge.log" <<LOG
unconfirmed $TORN ci-required: ci_verdict_unconfirmed_after_retry: ${TORN:0:12} ci-required was accepted as success but the status row still reads pending.
LOG

cat > "$tmp/lastgit" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$tmp/lastgit-calls"
case "\$1 \$2" in
  "cr list")
    case "\$*" in
      *"--state merged"*) cat "$tmp/merged-crs" ;;
      *)
        printf 'cr-torn\topen\tx->main\ttorn verdict\n'
        printf 'cr-running\topen\ty->main\tci still running\n'
        printf 'cr-green\topen\tz->main\talready green\n'
        ;;
    esac
    ;;
  "cr view")
    if [ "\$4" = cr-settled ]; then
      printf 'head_oid\t%s\n' "$SETTLED"
      printf 'base_branch\tmain\n'
      printf 'auto_merge\ttrue\n'
      printf 'require_status\tci-required\n'
      printf 'state\tmerged\n'
      printf 'merge_oid\t%s\n' "$MERGE_OID"
      exit 0
    fi
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
  *merge-base*)
    # repair_ref asks twice. "is <merge_oid> already in <cur>" decides landed;
    # "is <cur> an ancestor of <merge_oid>" decides fast-forward.
    # git -C <wt> merge-base --is-ancestor <A> <B> -> A is \$5.
    if [ "\$5" = "$MERGE_OID" ]; then exit "\$(cat "$tmp/contains")"; fi
    exit "\$(cat "$tmp/ancestor")" ;;
  *push*) echo "\$args" >> "$tmp/git-push"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$tmp/git"
echo 0 > "$tmp/ancestor"
echo 1 > "$tmp/contains"
: > "$tmp/merged-crs"

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

# --- the REPORT must not promise a fast-forward it cannot prove -------------
rm -f "$tmp/merged"; : > "$tmp/git-push"
printf 'cr-settled\tmerged\ts->main\tsettled merge\n' > "$tmp/merged-crs"
echo 1 > "$tmp/ancestor"; echo 1 > "$tmp/contains"
PATH="$tmp:$PATH" bash "$bin" --repos demo > "$tmp/dryref" 2>&1 \
  || { echo "FAIL: dry-run non-ff errored"; cat "$tmp/dryref"; exit 1; }
grep -q "would fast-forward" "$tmp/dryref" \
  && { echo "FAIL: report promised a fast-forward it cannot prove"; cat "$tmp/dryref"; exit 1; }
grep -q "REFUSED" "$tmp/dryref" \
  || { echo "FAIL: report did not refuse the non-fast-forward"; cat "$tmp/dryref"; exit 1; }
: > "$tmp/merged-crs"; echo 0 > "$tmp/ancestor"

# --- a pending row with no accepted-as-success line is left alone -----------
rm -f "$tmp/merged"; : > "$tmp/forge.log"; : > "$tmp/lastgit-calls"
PATH="$tmp:$PATH" bash "$bin" --repos demo --apply > "$tmp/noev" 2>&1 \
  || { echo "FAIL: no-evidence run errored"; cat "$tmp/noev"; exit 1; }
grep -q "cr merge" "$tmp/lastgit-calls" \
  && { echo "FAIL: merged without an accepted-as-success line"; exit 1; }
grep -q "merged=0" "$tmp/noev" \
  || { echo "FAIL: summary should report merged=0"; cat "$tmp/noev"; exit 1; }

# --- a SETTLED merged CR whose base ref never moved is landed --------------
# The row already reads `merged`, so it is absent from the open list; only the
# merged pass can see it. This is the shape that stranded last-stack
# cr-mtm5pr6u-ab38 and loom cr-mtm79teu-1af9 on 2026-09-04.
rm -f "$tmp/merged"; : > "$tmp/git-push"; : > "$tmp/forge.log"
echo 0 > "$tmp/ancestor"; echo 1 > "$tmp/contains"
printf 'cr-settled\tmerged\ts->main\tsettled merge\n' > "$tmp/merged-crs"
PATH="$tmp:$PATH" bash "$bin" --repos demo --apply > "$tmp/settled" 2>&1 \
  || { echo "FAIL: settled-merge run errored"; cat "$tmp/settled"; exit 1; }
grep -q "$MERGE_OID:refs/heads/main" "$tmp/git-push" \
  || { echo "FAIL: settled merged CR left its base ref unlanded"; cat "$tmp/settled"; exit 1; }

# --- a merged CR the base has already advanced PAST is not pushed backwards -
: > "$tmp/git-push"; echo 0 > "$tmp/contains"
PATH="$tmp:$PATH" bash "$bin" --repos demo --apply > "$tmp/adv" 2>&1 \
  || { echo "FAIL: advanced-base run errored"; cat "$tmp/adv"; exit 1; }
[ -s "$tmp/git-push" ] \
  && { echo "FAIL: pushed a base ref backwards over a landed merge"; cat "$tmp/git-push"; exit 1; }
grep -q "landed; base has advanced" "$tmp/adv" \
  || { echo "FAIL: did not report the merge as already landed"; cat "$tmp/adv"; exit 1; }
: > "$tmp/merged-crs"; echo 1 > "$tmp/contains"

echo "PASS: last-stack-lastgit-stuck-merge-heal"
