#!/usr/bin/env bash
# north-star-slug: north-star-exemem-hands-off-prod-deploy
# Terminal proof for hands-off exemem prod deploy.
# Offline and live modes are read-only. This file does not deploy, and it
# does not open a LastDB home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-exemem-hands-off-prod-deploy
MODE="$(ns_mode)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/exemem-hands-off-proof.XXXXXX")"
INFRA=""
OID="fixture"

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

# No deploy switch exists. A caller cannot turn this harness into a cutover.
if [ -n "${EXEMEM_HANDS_OFF_ALLOW_DEPLOY:-}" ]; then
  finish FAIL "This harness does not deploy. Remove EXEMEM_HANDS_OFF_ALLOW_DEPLOY."
fi

refuse_primary_root() {
  local candidate="$1"
  case "$candidate" in
    "$HOME/.lastdb"|"$HOME/.lastdb/"*|"$HOME/.folddb"|"$HOME/.folddb/"*)
      finish FAIL "The harness refuses a LastDB home path."
      ;;
  esac
}

materialize_git() {
  local git_dir="$1" dest="$2"
  [ -n "$git_dir" ] || return 1
  [ -d "$git_dir" ] || return 1
  git --git-dir="$git_dir" rev-parse --verify --quiet 'main^{commit}' >/dev/null 2>&1 || return 1
  mkdir -p "$dest/.lastgit" "$dest/cdk/lib"
  git --git-dir="$git_dir" show 'main:.lastgit/deploy-pipeline.sh' >"$dest/.lastgit/deploy-pipeline.sh"
  git --git-dir="$git_dir" show 'main:.lastgit/canary-ticker.sh' >"$dest/.lastgit/canary-ticker.sh"
  git --git-dir="$git_dir" show 'main:cdk/lib/exemem-stack.ts' >"$dest/cdk/lib/exemem-stack.ts"
  OID="$(git --git-dir="$git_dir" rev-parse 'main^{commit}')"
}

resolve_infra() {
  local portal git_dir archived
  if [ -n "${EXEMEM_HANDS_OFF_INFRA_ROOT:-}" ]; then
    INFRA="${EXEMEM_HANDS_OFF_INFRA_ROOT}"
    OID="fixture"
    return 0
  fi
  git_dir="${EXEMEM_INFRA_GIT_DIR:-}"
  if [ -z "$git_dir" ]; then
    portal="$(ns_edgevector_workspace)/exemem-infra/.portal/cache"
    if [ -f "$portal" ]; then
      git_dir="$(tr -d '[:space:]' <"$portal")"
    fi
  fi
  if materialize_git "$git_dir" "$TMP/src"; then
    INFRA="$TMP/src"
    return 0
  fi
  archived="$(ns_repo_path exemem-infra)"
  INFRA="$archived"
  if git -C "$archived" rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null 2>&1; then
    OID="$(git -C "$archived" rev-parse 'HEAD^{commit}')"
  else
    OID="unresolved"
  fi
}

resolve_infra
refuse_primary_root "$INFRA"

EVIDENCE="${EXEMEM_HANDS_OFF_PROOF_EVIDENCE_FILE:-}"
NS_TEXT=""
PROOF_TEXT=""
if [ -z "$EVIDENCE" ] && [ -n "${EXEMEM_HANDS_OFF_PROOF_BRAIN_DIR:-}" ]; then
  NS_TEXT="${EXEMEM_HANDS_OFF_PROOF_BRAIN_DIR}/ns.txt"
  PROOF_TEXT="${EXEMEM_HANDS_OFF_PROOF_BRAIN_DIR}/proof.txt"
elif [ -z "$EVIDENCE" ]; then
  NS_TEXT="$TMP/ns.txt"
  PROOF_TEXT="$TMP/proof.txt"
  if command -v gbrain >/dev/null 2>&1; then
    gbrain get projects/north-star-exemem-hands-off-prod-deploy >"$NS_TEXT" 2>"$TMP/ns.err" || true
    gbrain get reference/proof-exemem-prod-live-fire-window-20260903 >"$PROOF_TEXT" 2>"$TMP/proof.err" || true
  fi
fi

set +e
body="$(python3 - "$INFRA" "$EVIDENCE" "$NS_TEXT" "$PROOF_TEXT" "$MODE" "$OID" <<'PY'
import json
import sys
from pathlib import Path

infra = Path(sys.argv[1])
evidence_path = sys.argv[2]
ns_path = sys.argv[3]
proof_path = sys.argv[4]
mode = sys.argv[5]
oid = sys.argv[6]

notes = []
failures = []

def add_pass(line):
    notes.append(f"- PASS: {line}")

def add_fail(line):
    failures.append(line)
    notes.append(f"- FAIL: {line}")

def read_text(path):
    file_path = Path(path)
    if not path or not file_path.is_file():
        return ""
    return file_path.read_text(errors="replace")

def require_text(relative, needles, banned=()):
    path = infra / relative
    if not path.is_file():
        add_fail(f"{relative} is absent.")
        return
    text = path.read_text(errors="replace")
    missing = [needle for needle in needles if needle not in text]
    present_banned = [needle for needle in banned if needle in text]
    if missing or present_banned:
        detail = []
        if missing:
            detail.append("absent markers: " + "; ".join(missing))
        if present_banned:
            detail.append("forbidden markers: " + "; ".join(present_banned))
        add_fail(f"{relative} does not match the contract ({'; '.join(detail)}).")
        return
    add_pass(f"{relative} matches the hands-off contract.")

require_text(
    ".lastgit/deploy-pipeline.sh",
    (
        'if [ "${DEPLOY_FREEZE:-}" = "true" ]; then',
        'write_progress frozen "DEPLOY_FREEZE"',
        'record_terminal success "skip=freeze"',
        "Deploy PROD (us-east-1)",
        "pin ~10% traffic",
    ),
    ("confirm_prod_sha",),
)
require_text(
    ".lastgit/canary-ticker.sh",
    (
        'if [ "${DEPLOY_FREEZE:-}" = "true" ]; then',
        "canary_alarms_ok",
        "rolling back",
        "PROMOTED",
        "100%",
    ),
)
require_text(
    "cdk/lib/exemem-stack.ts",
    (
        "CodeDeploy canary traffic shifting + auto-rollback",
        "No human action.",
        "CANARY_10PERCENT_5MINUTES",
        "deploymentInAlarm",
        "OBS_SENTRY_DSN",
        "Exemem-Alarms-",
    ),
)

SECRET_KEYS = (
    "password",
    "secret",
    "token",
    "api_key",
    "aws_secret_access_key",
    "session",
    "dsn",
)

def walk_keys(obj, acc):
    if isinstance(obj, dict):
        for key, value in obj.items():
            acc.append(str(key).lower())
            walk_keys(value, acc)
    elif isinstance(obj, list):
        for item in obj:
            walk_keys(item, acc)

def require_bool(data, name, expected):
    if data.get(name) is not expected:
        add_fail(f"{name} must be {str(expected).lower()}.")
        return
    add_pass(f"{name} is {str(expected).lower()}.")

def check_evidence_object(data, origin):
    notes.append(f"Evidence origin: {origin}.")
    if data.get("schema") != "exemem-hands-off-prod-proof.v1":
        add_fail("The evidence schema is not exemem-hands-off-prod-proof.v1.")
    require_bool(data, "primary_lastdb_opened", False)
    require_bool(data, "prod_mutated_by_harness", False)
    require_bool(data, "human_confirm_gate_present", False)
    require_bool(data, "hands_off_promotion_100", True)
    require_bool(data, "deploy_freeze_skips_prod", True)
    require_bool(data, "alarm_rollback_without_manual", True)
    require_bool(data, "sentry_failure_visible", True)
    refs = data.get("evidence_refs")
    if not isinstance(refs, list) or not refs:
        add_fail("evidence_refs must name at least one record.")
    else:
        bad_ref = False
        for ref in refs:
            if not isinstance(ref, str) or not ref.strip() or any(ch.isspace() for ch in ref) or len(ref) > 200:
                bad_ref = True
        if bad_ref:
            add_fail("evidence_refs must be short single tokens.")
        else:
            add_pass("evidence_refs names " + ", ".join(refs) + ".")
    keys = []
    walk_keys(data, keys)
    blob = json.dumps(data)
    for secretish in SECRET_KEYS:
        if secretish in keys:
            add_fail(f"The evidence uses a forbidden key: {secretish}.")
    if "hooks.sentry.io" in blob or "AKIA" in blob:
        add_fail("The evidence contains a secret-shaped value.")

def brain_evidence(ns_text, proof_text):
    if not ns_text.strip() and not proof_text.strip():
        add_fail("The recorded terminal proof is absent.")
        return
    promo = "prod canary promoted to 100%" in ns_text or "prod canary promoted to 100%" in proof_text
    freeze = (
        "Freeze proof - PASS" in proof_text
        and "stage=frozen" in proof_text
        and "DEPLOY_FREEZE" in proof_text
    )
    rollback = (
        "Broken-canary auto-rollback - PASS" in proof_text
        and "ALARM_ACTIVE" in proof_text
        and "No manual intervention" in proof_text
    )
    sentry_blocked = (
        "is EMPTY on every prod lambda" in proof_text
        or "No prod lambda can send a Sentry event" in proof_text
    )
    sentry_marked = "SENTRY_FAILURE_VISIBLE: yes" in proof_text or "SENTRY_FAILURE_VISIBLE: yes" in ns_text
    sentry_visible = sentry_marked and not sentry_blocked
    check_evidence_object(
        {
            "schema": "exemem-hands-off-prod-proof.v1",
            "primary_lastdb_opened": False,
            "prod_mutated_by_harness": False,
            "human_confirm_gate_present": False,
            "hands_off_promotion_100": promo,
            "deploy_freeze_skips_prod": freeze,
            "alarm_rollback_without_manual": rollback,
            "sentry_failure_visible": sentry_visible,
            "evidence_refs": [
                "projects/north-star-exemem-hands-off-prod-deploy",
                "reference/proof-exemem-prod-live-fire-window-20260903",
            ],
        },
        "recorded brain proof",
    )
    if sentry_blocked:
        add_fail(
            "The live-fire proof says the prod Sentry DSN is empty, so a failure is not visible in Sentry."
        )

if evidence_path:
    path = Path(evidence_path)
    if not path.is_file():
        add_fail("The evidence file is absent.")
    else:
        try:
            data = json.loads(path.read_text())
        except json.JSONDecodeError:
            add_fail("The evidence file is not JSON.")
            data = None
        if isinstance(data, dict):
            check_evidence_object(data, str(path))
        elif data is not None:
            add_fail("The evidence file must be a JSON object.")
else:
    brain_evidence(read_text(ns_path), read_text(proof_path))

lines = [
    "Hands-off exemem prod deploy terminal proof.",
    f"Mode: {mode}.",
    f"Source oid: {oid}.",
    "The harness does not deploy.",
    "The harness does not open a LastDB home.",
    "",
    "Checks:",
    *notes,
]
if failures:
    lines.extend(["", "The proof is not complete:"])
    lines.extend(f"- {line}" for line in failures)
print("\n".join(lines))
sys.exit(1 if failures else 0)
PY
)"
py_rc=$?
set -e

if [ "$py_rc" -eq 0 ]; then
  if [ "$MODE" = live ]; then
    finish PASS "$body"
  else
    finish PASS-OFFLINE "$body"
  fi
fi

if [ -z "$body" ]; then
  body="The checker stopped before it wrote a result."
fi
finish FAIL "$body"
