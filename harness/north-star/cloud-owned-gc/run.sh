#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-cloud-owned-gc
# Required terminal proof registration for cloud-owned LastDB GC.
#
# This harness owns REGISTRATION and the EVIDENCE HANDOFF, not the proof.
# The proof itself is Fold's P9 verifier
# (scripts/prove-cloud-owned-gc --require-full-release-proof): the real-data
# copy, concurrent publication, source-device disconnect, fresh cloud restore
# and exact byte reconciliation from plan-lastdb-cloud-owned-gc-20260912. This
# harness invokes that verifier, re-reads the evidence it wrote, and refuses
# every shortcut. It never opens a LastDB home, socket or cloud account.
#
# Why it exists: the milestone driver read "no registered harness" as
# proof_status=not_required, so an unproven North Star could complete. With
# this folder present the runner always has a verdict, and until P9 lands that
# verdict is FAIL with a named missing-proof reason.
#
# Evidence handoff contract (what scripts/prove-cloud-owned-gc must do):
#   * It receives `--require-full-release-proof` as its only argument.
#   * Env CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE names the file it must write.
#   * Env CLOUD_OWNED_GC_PROOF_NONCE is a per-invocation token; the evidence
#     must echo it on a `- Harness nonce:` line, so a stale file from an
#     earlier run can never be read as this run's proof.
#   * Env NORTH_STAR_PROOF_MODE is `offline` or `live`. In offline mode the
#     verifier must not run real-data or cloud work; it may only re-validate a
#     recorded full-release proof and re-emit it with the new nonce.
#   * Exit 0 means the full release proof holds. Any other exit is a failure,
#     whatever the output says.
#   * Evidence line 1 is PASS or FAIL. The remaining required lines are listed
#     in REQUIRED_PASS_FIELDS and the checks below. Scope must be exactly
#     `full-release`; private DEV, model-only or partial scopes are refused.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-cloud-owned-gc
MODE="$(ns_mode)"
VERIFIER_REL="scripts/prove-cloud-owned-gc"
FULL_PROOF_FLAG="--require-full-release-proof"

# The evidence file is Fold's OUTPUT and this harness's INPUT. It must never be
# the report this harness writes (the io-free harness once collapsed the two
# onto one path and self-certified).
EVIDENCE="${CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE:-$(ns_proof_dir)/$SLUG.fold-evidence.md}"
REPORT="$(ns_proof_dir)/$SLUG.md"

# Every field that must read exactly PASS in the evidence.
REQUIRED_PASS_FIELDS=(
  "Physical absence before boot"
  "Retained controls"
  "Fresh cloud restore"
  "Concurrent publication"
  "Source device disconnected before completion"
  "Exact object bytes reconciled"
)
# Every payload class the plan names; a Delete is not cloud-erased until each
# adapter reports, so the evidence must list all of them.
REQUIRED_PAYLOAD_CLASSES=(backup-chunks manifests mutation-logs owned-file-versions declared-caches)

notes=()
failed=0
pass_note() { notes+=("$1: PASS"); }
fail_note() { notes+=("$1: FAIL"); failed=1; }

abs_path() {
  # readlink -f is GNU-only; macOS /bin/bash may lack it.
  local p="$1" dir base
  dir="$(dirname "$p")"
  base="$(basename "$p")"
  if [ -d "$dir" ]; then
    printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
  else
    printf '%s\n' "$p"
  fi
}

evidence_field() {
  # evidence_field <label> -> value of the first `- <label>: value` line, or "".
  sed -n "s/^- $1: *//p" "$EVIDENCE" | head -n 1 | sed 's/[[:space:]]*$//'
}

# --- 1. Resolve the Fold source through supported helpers -------------------
# An explicit DEV worktree or extracted release source wins. Otherwise
# ns_repo_path honors FOLD_REPO and falls back to an archive of the fold
# mirror. The workspace portal itself is never a source tree.
FOLD=""
FOLD_ORIGIN=""
TREE_OID=""
if [ -n "${CLOUD_OWNED_GC_FOLD_SOURCE:-}" ]; then
  FOLD="$CLOUD_OWNED_GC_FOLD_SOURCE"
  FOLD_ORIGIN="CLOUD_OWNED_GC_FOLD_SOURCE"
else
  FOLD="$(ns_repo_path fold)"
  FOLD_ORIGIN="ns_repo_path fold"
fi

if [ ! -d "$FOLD" ]; then
  fail_note "fold source resolves to a directory ($FOLD_ORIGIN gave '$FOLD', which does not exist)"
elif [ -e "$FOLD/.portal" ]; then
  fail_note "fold source is a real tree ($FOLD is the workspace portal, which holds no checkout; set FOLD_REPO or CLOUD_OWNED_GC_FOLD_SOURCE)"
else
  pass_note "fold source resolved at $FOLD via $FOLD_ORIGIN"
  if [ -n "${CLOUD_OWNED_GC_FOLD_SOURCE_OID:-}" ]; then
    TREE_OID="$CLOUD_OWNED_GC_FOLD_SOURCE_OID"
  elif command -v git >/dev/null 2>&1; then
    TREE_OID="$(git -C "$FOLD" rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null || true)"
  fi
fi

# --- 2. The verifier must exist; its absence is the named missing proof -----
VERIFIER="$FOLD/$VERIFIER_REL"
if [ "$failed" -eq 0 ]; then
  if [ -f "$VERIFIER" ]; then
    pass_note "verifier $VERIFIER_REL is present"
  else
    fail_note "missing-proof: Fold verifier $VERIFIER_REL is absent at $FOLD (P9 has not landed; no substitute is accepted)"
  fi
fi

if [ "$(abs_path "$EVIDENCE")" = "$(abs_path "$REPORT")" ]; then
  fail_note "evidence file $EVIDENCE is this harness's own report; point CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE at Fold's evidence"
fi

# --- 3. Invoke the verifier with the exact full-proof flag ------------------
VERIFIER_RC=""
VERIFIER_LOG=""
NONCE=""
if [ "$failed" -eq 0 ]; then
  NONCE="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  VERIFIER_LOG="$(mktemp "${TMPDIR:-/tmp}/ns-cloud-owned-gc-verifier.XXXXXX")"
  mkdir -p "$(dirname "$EVIDENCE")"
  set +e
  CLOUD_OWNED_GC_PROOF_EVIDENCE_FILE="$EVIDENCE" \
  CLOUD_OWNED_GC_PROOF_NONCE="$NONCE" \
  NORTH_STAR_PROOF_MODE="$MODE" \
    bash "$VERIFIER" "$FULL_PROOF_FLAG" >"$VERIFIER_LOG" 2>&1
  VERIFIER_RC=$?
  set -e
  if [ "$VERIFIER_RC" -eq 0 ]; then
    pass_note "verifier exited 0 with $FULL_PROOF_FLAG"
  else
    # A printed PASS token cannot overrule the exit status.
    fail_note "verifier exited $VERIFIER_RC with $FULL_PROOF_FLAG (last output: $(tail -n 1 "$VERIFIER_LOG" | cut -c1-160))"
  fi
fi

# --- 4. Re-read the evidence; every claim must be complete and bound --------
if [ -n "$VERIFIER_RC" ]; then
  if [ ! -f "$EVIDENCE" ]; then
    fail_note "verifier wrote evidence at $EVIDENCE"
  else
    verdict="$(sed -n '1p' "$EVIDENCE")"
    if [ "$verdict" = PASS ]; then
      pass_note "evidence verdict is PASS"
    else
      fail_note "evidence verdict is PASS (found '${verdict:-empty}')"
    fi

    nonce_seen="$(evidence_field 'Harness nonce')"
    if [ -n "$NONCE" ] && [ "$nonce_seen" = "$NONCE" ]; then
      pass_note "evidence carries this invocation's nonce"
    else
      fail_note "evidence carries this invocation's nonce (found '${nonce_seen:-none}'; a stale or foreign evidence file is not this run's proof)"
    fi

    scope="$(evidence_field 'Proof scope')"
    if [ "$scope" = full-release ]; then
      pass_note "proof scope is full-release"
    else
      fail_note "proof scope is full-release (found '${scope:-missing}'; private DEV, model-only or partial scopes cannot complete this North Star)"
    fi

    src_oid="$(evidence_field 'Source oid')"
    if printf '%s' "$src_oid" | grep -qE '^[0-9a-f]{40}$'; then
      if [ -n "$TREE_OID" ] && [ "$TREE_OID" != "$src_oid" ]; then
        fail_note "evidence source oid $src_oid matches the resolved tree ($TREE_OID)"
      else
        pass_note "evidence is bound to source oid $src_oid"
      fi
    else
      fail_note "evidence is bound to a source oid (found '${src_oid:-missing}')"
    fi

    daemon_sha="$(evidence_field 'Daemon sha256')"
    if printf '%s' "$daemon_sha" | grep -qE '^[0-9a-f]{64}$'; then
      pass_note "evidence is bound to daemon sha256 $daemon_sha"
    else
      fail_note "evidence is bound to a daemon sha256 (found '${daemon_sha:-missing}')"
    fi

    fixture="$(evidence_field 'Fixture')"
    case "$fixture" in
      *isolated\ copy*) pass_note "fixture is an isolated copy" ;;
      *) fail_note "fixture is an isolated copy (found '${fixture:-missing}'; a first probe against the primary is refused)" ;;
    esac

    classes="$(evidence_field 'Payload classes complete')"
    missing_classes=""
    for cls in "${REQUIRED_PAYLOAD_CLASSES[@]}"; do
      case " $(printf '%s' "$classes" | tr ',' ' ') " in
        *" $cls "*) ;;
        *) missing_classes="$missing_classes $cls" ;;
      esac
    done
    if [ -z "$missing_classes" ]; then
      pass_note "every payload class reports complete erasure"
    else
      fail_note "every payload class reports complete erasure (missing:${missing_classes})"
    fi

    for field in "${REQUIRED_PASS_FIELDS[@]}"; do
      value="$(evidence_field "$field")"
      if [ "$value" = PASS ]; then
        pass_note "$field"
      else
        fail_note "$field (found '${value:-missing}')"
      fi
    done

    cold_boots="$(evidence_field 'Cold boots')"
    if printf '%s' "$cold_boots" | grep -qE '^[0-9]+$' && [ "$cold_boots" -ge 2 ]; then
      pass_note "cold boots: $cold_boots (at least 2)"
    else
      fail_note "cold boots are at least 2 (found '${cold_boots:-missing}')"
    fi
  fi
fi
[ -z "$VERIFIER_LOG" ] || rm -f "$VERIFIER_LOG"

# --- 5. Report -------------------------------------------------------------
body=""
for note in "${notes[@]}"; do
  body="${body}- ${note}"$'\n'
done
body="${body}"$'\n'"Mode: $MODE. Verifier: \`$VERIFIER_REL $FULL_PROOF_FLAG\`. Evidence file: \`$EVIDENCE\`."$'\n'
body="${body}This harness registers the proof and checks the evidence handoff; it never opens a LastDB home, socket or cloud account, and no code presence, unit test, PR count or printed PASS token can replace the full release proof."

if [ "$failed" -eq 0 ]; then
  if [ "$MODE" = live ]; then
    ns_write_report "$SLUG" PASS "$body"
  else
    ns_write_report "$SLUG" PASS-OFFLINE "$body"
  fi
else
  ns_write_report "$SLUG" FAIL "$body"
fi
