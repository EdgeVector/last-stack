#!/usr/bin/env bash
# north-star-slug: north-star-portable-routine-fleet
# Offline terminal proof for the portable routine fleet.
# Fills the bootstrap kit for a second project and checks the generic engines.
# Does not open a shared LastDB home. Does not run a canary upgrade.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-portable-routine-fleet
MODE="$(ns_mode)"
TEMPLATE_DIR="${PORTABLE_FLEET_TEMPLATE_DIR:-$ROOT/templates/routine-fleet}"
ROUTINES_DIR="${PORTABLE_FLEET_ROUTINES_DIR:-$ROOT/routines}"
ROTATOR_SKILL="${PORTABLE_FLEET_ROTATOR_SKILL:-$ROOT/skills/registry-rotator/SKILL.md}"
MINER_SKILL="${PORTABLE_FLEET_MINER_SKILL:-$ROOT/skills/session-miner/SKILL.md}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/portable-fleet-proof.XXXXXX")"
BODY_FILE="$WORK/body.md"
ERR_FILE="$WORK/err.txt"

cleanup() {
  rm -rf "$WORK"
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

refuse_primary_path() {
  local label="$1" candidate="$2"
  case "$candidate" in
    "$HOME/.lastdb"|"$HOME/.lastdb/"*|"$HOME/.folddb"|"$HOME/.folddb/"*)
      finish FAIL "The harness refuses ${label} because it is a primary LastDB home."
      ;;
  esac
}

case "$MODE" in
  offline|live) ;;
  *)
    finish FAIL "The proof mode is invalid: $MODE."
    ;;
esac

proof_dir="$(ns_proof_dir)"
refuse_primary_path "the proof directory" "$proof_dir"
refuse_primary_path "the template directory" "$TEMPLATE_DIR"
refuse_primary_path "the routines directory" "$ROUTINES_DIR"
refuse_primary_path "the registry-rotator skill" "$ROTATOR_SKILL"
refuse_primary_path "the session-miner skill" "$MINER_SKILL"

set +e
python3 - "$TEMPLATE_DIR" "$ROUTINES_DIR" "$ROTATOR_SKILL" "$MINER_SKILL" "$WORK/filled" "$MODE" >"$BODY_FILE" 2>"$ERR_FILE" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

template_dir = Path(sys.argv[1])
routines_dir = Path(sys.argv[2])
rotator_skill = Path(sys.argv[3])
miner_skill = Path(sys.argv[4])
filled_dir = Path(sys.argv[5])
mode = sys.argv[6]

failures = []
notes = []

REQUIRED_TEMPLATES = (
    "workspace-config.md",
    "repo-venue-map.md",
    "tag-repo-map.md",
    "signal-sources.md",
    "probe-registry.md",
    "sop-routine-shared-contract.md",
)

PLACEHOLDER_RE = re.compile(r"<[A-Z][A-Z0-9_]*>")
SECRET_NAME_RE = re.compile(r"(TOKEN|SECRET|PASSWORD|AUTH|DSN|CREDENTIAL|API_KEY)")
RAW_SECRET_RE = re.compile(r"(ghp_[A-Za-z0-9]|github_pat_|AKIA[0-9A-Z]{8}|sk-[A-Za-z0-9]|BEGIN PRIVATE)")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")

# One hypothetical project. Repo tokens stay aligned across the kit so the
# tag map is a subset of the venue map without an engine edit.
VALUES = {
    "PROJECT_NAME": "Harbor",
    "PROJECT": "harbor",
    "OWNER_NAME_OR_TEAM": "Harbor Team",
    "OWNER_CONTACT": "owner@harbor.invalid",
    "BRAIN_DAEMON_NAME": "harbor-brain",
    "PRIMARY_BRAIN_GUARDRAIL": "harbor-brain",
    "FORGE_SERVICE_GUARDRAIL": "harbor-forge",
    "OTHER_GUARDRAIL": "harbor-board",
    "FORGE_URL": "https://forge.harbor.invalid",
    "FORGE_TOKEN_REF": "lastsecrets://harbor-forge-token",
    "BOARD_CLI": "board",
    "BRAIN_CLI": "brain",
    "SITUATIONS_CLI_OR_NONE": "none",
    "PAPERCUT_LEDGER_CLI_OR_NONE": "brain papercut file",
    "PAPERCUT_RECONCILER_ROUTINE_OR_NONE": "papercut-reconciler",
    "REPO_OR_PATH_1": "harbor/archive",
    "REPO_OR_PATH_2": "harbor/mirror",
    "PATH_PREFIX": "/usr/bin",
    "BASE_BRANCH": "main",
    "GITHUB_OWNER": "harbor",
    "FORGE_OWNER": "harbor",
    "OWNER": "harbor",
    "ORG": "harbor",
    "GITHUB_REPO": "api",
    "REPO": "api",
    "REPO_1": "api",
    "FORGE_REPO": "web",
    "REPO_2": "web",
    "GITHUB_CHECK_CONTEXT": "ci-required",
    "FORGE_CHECK_CONTEXT": "ci-required",
    "LASTGIT_STATUS_CONTEXT": "ci-required",
    "REQUIRED_CHECK_NAME_OR_NONE": "ci-required",
    "MERGE_MECHANISM": "forgejo-auto",
    "LASTGIT_REPO_SLUG": "harbor-notes",
    "TAG_1": "api",
    "TAG_2": "web",
    "TAG": "api",
    "TAGS": "api,web",
    "AMBIGUOUS_TAG": "shared",
    "SOURCE_AUTH_SECRET_REF": "lastsecrets://harbor-source-auth",
    "SENTRY_TOKEN_REF": "lastsecrets://harbor-sentry-token",
    "SENTRY_API_URL": "https://sentry.harbor.invalid",
    "SOURCE_API_URL": "https://signals.harbor.invalid",
    "P_LEVEL": "P1",
    "N": "1",
    "PASS": "exit-zero",
}


def add_fail(line):
    failures.append(line)


def add_note(line):
    notes.append(line)


def digest(path):
    data = path.read_bytes()
    return hashlib.sha256(data).hexdigest(), data


def value_for(token, work_root):
    name = token[1:-1]
    if name in VALUES:
        return VALUES[name]
    dynamic = {
        "WORKSPACE_ROOT": str(work_root),
        "BRAIN_SOCKET_PATH": str(work_root / "harbor-brain.sock"),
        "AGENT_WORKTREE_DIR": str(work_root / "worktrees"),
        "SESSION_TRANSCRIPTS_PATH": str(work_root / "transcripts"),
        "SCHEDULED_TASKS_DIR": str(work_root / "routines"),
        "PRIMARY_DATA_DIR": str(work_root / "primary-data"),
        "TMP_DIR": str(work_root / "tmp"),
        "PID_FILE": str(work_root / "probe.pid"),
        "PATH_TO_SCRIPT": str(work_root / "probe.sh"),
    }
    if name in dynamic:
        return dynamic[name]
    slug = name.lower().replace("_", "-")
    if SECRET_NAME_RE.search(name):
        return "lastsecrets://harbor-" + slug
    return "harbor-" + slug


def fill_text(text, work_root):
    seen = []

    def replace(match):
        token = match.group(0)
        seen.append(token)
        return value_for(token, work_root)

    filled = PLACEHOLDER_RE.sub(replace, text)
    leftover = PLACEHOLDER_RE.findall(filled)
    return filled, seen, leftover


def strip_cell(cell):
    return cell.strip().strip("`").strip()


def mapped_repos(text):
    repos = []
    for line in text.splitlines():
        if not line.startswith("|"):
            continue
        cells = [strip_cell(cell) for cell in line.strip().strip("|").split("|")]
        if len(cells) < 2:
            continue
        repo = cells[1]
        if repo in {"Repo:", "---", ""} or "unmapped" in repo:
            continue
        if REPO_RE.match(repo):
            repos.append(repo)
    return repos


def section_value(section, field):
    match = re.search(r"\*\*" + re.escape(field) + r"\*\*:\s*`?([^`\n]+)", section)
    if not match:
        return ""
    return match.group(1).strip()


def is_rotator_trigger(text):
    if "registry-rotator" not in text:
        return False
    if "registry=" in text:
        return True
    return "thin trigger" in text.lower()


def is_miner_trigger(text):
    if "session-miner" not in text:
        return False
    # A thin trigger passes profile= as its own input line
    # (routines/revenant-watch.md: "profile=revenant-watch"). A sentence that
    # only mentions profile= does not make a routine a trigger: with a
    # substring match, self-improvement-loop.md counted and the proof printed
    # a false PASS-OFFLINE (Loom review p1 on last-stack#166).
    if re.search(r"(?m)^\s*profile=\S", text):
        return True
    return "Follow the **session-miner** skill" in text


work_root = filled_dir / "harbor-workspace"
filled_dir.mkdir(parents=True, exist_ok=True)
work_root.mkdir(parents=True, exist_ok=True)

rotator_before = miner_before = None
if rotator_skill.is_file():
    rotator_before = digest(rotator_skill)
if miner_skill.is_file():
    miner_before = digest(miner_skill)

missing_templates = [name for name in REQUIRED_TEMPLATES if not (template_dir / name).is_file()]
if missing_templates:
    add_fail("Missing bootstrap template: " + ", ".join(missing_templates))
else:
    filled_count = 0
    placeholder_count = 0
    for name in REQUIRED_TEMPLATES:
        source = template_dir / name
        original = source.read_text()
        filled, seen, leftover = fill_text(original, work_root)
        (filled_dir / name).write_text(filled)
        filled_count += 1
        placeholder_count += len(seen)
        if leftover:
            add_fail(name + " still has placeholders: " + ", ".join(sorted(set(leftover))))
        if ".lastdb" in filled or ".folddb" in filled:
            add_fail(name + " names a primary LastDB home after the fill.")
        if "EdgeVector" in filled:
            add_fail(name + " still names EdgeVector after the fill.")
        if RAW_SECRET_RE.search(filled):
            add_fail(name + " contains a raw secret after the fill.")
        for line in filled.splitlines():
            if re.search(r"(forge_token_ref|auth_ref)\*\*:", line) and "lastsecrets://" not in line:
                add_fail(name + " has a secret field without a lastsecrets locator.")
    add_note("Templates filled: " + str(filled_count))
    add_note("Placeholder occurrences filled: " + str(placeholder_count))

    venue_text = (filled_dir / "repo-venue-map.md").read_text()
    tag_text = (filled_dir / "tag-repo-map.md").read_text()
    repos = mapped_repos(tag_text)
    if len(repos) < 2:
        add_fail("The filled tag map has fewer than two repos.")
    else:
        absent = [repo for repo in repos if repo not in venue_text]
        if absent:
            add_fail("Tag-map repos absent from the venue map: " + ", ".join(absent))
        else:
            add_note("Tag-map repos present in the venue map: " + ", ".join(repos))

    probe_text = (filled_dir / "probe-registry.md").read_text()
    if "Repo:" not in probe_text or "Base:" not in probe_text:
        add_fail("The filled probe registry has no Repo and Base card contract.")
    sections = re.split(r"\n### ", probe_text)
    probe_sections = 0
    for section in sections:
        if "**pass_assertion**" not in section and "**harness**" not in section:
            continue
        probe_sections += 1
        assertion = section_value(section, "pass_assertion")
        isolation = section_value(section, "isolation")
        harness = section_value(section, "harness")
        if not assertion or not isolation or not harness:
            add_fail("A probe entry lacks harness, pass_assertion, or isolation.")
            continue
        if "throwaway" not in isolation and str(work_root) not in isolation:
            add_fail("A probe isolation line does not name a throwaway surface.")
        if ".lastdb" in isolation or ".folddb" in isolation:
            add_fail("A probe isolation line names a primary LastDB home.")
    if probe_sections < 1:
        add_fail("The filled probe registry has no probe entry.")
    else:
        add_note("Probe entries checked: " + str(probe_sections))

    contract_text = (filled_dir / "sop-routine-shared-contract.md").read_text()
    if "sop-routine-shared-contract" not in contract_text:
        add_fail("The shared contract template lost its slug.")
    if "heartbeat_record" not in contract_text:
        add_fail("The shared contract template has no heartbeat record field.")

if not routines_dir.is_dir():
    add_fail("The routines directory is absent.")
    rotator_names = []
    miner_names = []
else:
    rotator_names = []
    miner_names = []
    for path in sorted(routines_dir.glob("*.md")):
        if path.name == "README.md":
            continue
        text = path.read_text(errors="replace")
        if "name:" not in "\n".join(text.splitlines()[:20]):
            continue
        if is_rotator_trigger(text):
            rotator_names.append(path.stem)
        if is_miner_trigger(text):
            miner_names.append(path.stem)
    if len(rotator_names) < 2:
        add_fail(
            "registry-rotator thin triggers: "
            + str(len(rotator_names))
            + " (need 2)."
        )
    else:
        add_note("registry-rotator triggers: " + ", ".join(rotator_names))
    if len(miner_names) < 2:
        add_fail(
            "session-miner thin triggers: " + str(len(miner_names)) + " (need 2)."
        )
    else:
        add_note("session-miner triggers: " + ", ".join(miner_names))


def require_engine(path, before, needles, label):
    if not path.is_file():
        add_fail(label + " skill is absent.")
        return
    text = path.read_text(errors="replace")
    for needle in needles:
        if needle not in text:
            add_fail(label + " skill lost the contract text: " + needle)
    if ".lastdb" in text or ".folddb" in text:
        add_fail(label + " skill names a primary LastDB home.")
    if "sop-routine-shared-contract" not in text:
        add_fail(label + " skill does not cite sop-routine-shared-contract.")
    later = digest(path)
    if before is None or later[0] != before[0] or later[1] != before[1]:
        add_fail(label + " skill bytes changed during the dry-run.")
    else:
        add_note(label + " bytes unchanged: " + before[0][:12])


require_engine(
    rotator_skill,
    rotator_before,
    (
        "registry=<slug-or-app-ref>",
        "Never embed EdgeVector-specific paths",
        "mode=dry-run|run",
    ),
    "registry-rotator",
)
require_engine(
    miner_skill,
    miner_before,
    (
        "profile=<papercuts|incidents|owner-statements|friction-patterns|revenant-watch>",
        "Do not hard-code EdgeVector paths",
        "report-only",
    ),
    "session-miner",
)

add_note("Mode: " + mode)
add_note("The harness did not open a shared LastDB home.")
add_note("The harness did not run a canary upgrade.")
add_note("Second project: Harbor")

lines = ["Offline proof for the portable routine fleet.", ""]
for note in notes:
    lines.append("- " + note)
if failures:
    lines.append("")
    lines.append("Failures:")
    for failure in failures:
        lines.append("- " + failure)
sys.stdout.write("\n".join(lines) + "\n")
sys.exit(1 if failures else 0)
PY
py_rc=$?
set -e

body="$(cat "$BODY_FILE" 2>/dev/null || true)"
if [ -s "$ERR_FILE" ]; then
  body="$(printf '%s\n\nChecker error:\n%s\n' "$body" "$(cat "$ERR_FILE")")"
fi
if [ -z "$body" ]; then
  body="The portable-fleet checker produced no report."
fi

if [ "$py_rc" -ne 0 ]; then
  finish FAIL "$body"
fi

# Offline and live both stop at the cause contract. A bare PASS would claim
# the week-of-heartbeats dogfood, and this harness does not measure that.
finish PASS-OFFLINE "$body"
