#!/usr/bin/env bash
# Graph A steps. Default stand-in. LOOM_LIVE=1 calls safe-upgrade-lastdb.sh.
set -euo pipefail
step="${1:?step}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
export LOOM_LASTDB_FRESHNESS_SCRIPT="${LOOM_LASTDB_FRESHNESS_SCRIPT:-$SCRIPT_DIR/lastdb-candidate-freshness.py}"
export LOOM_SAFE_UPGRADE_GRAPH="${LOOM_SAFE_UPGRADE_GRAPH:-$SCRIPT_DIR/lastdb-safe-upgrade.json}"

python3 - "$step" <<'PY'
import hashlib, json, os, re, subprocess, sys
from pathlib import Path

step = sys.argv[1]
raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

item = ctx.get("item")
if isinstance(item, dict):
    immutable = (
        "candidate",
        "candidate_cli",
        "version",
        "lastdbd_version",
        "lastdb_version",
        "lastdbd_sha256",
        "lastdb_sha256",
        "source_git_oid",
        "candidate_artifact_digest",
        "safe_upgrade_protocol_version",
    )
    conflicts = [
        key for key in immutable
        if key in item and key in ctx and item.get(key) != ctx.get(key)
    ]
    if conflicts:
        print(
            "safe-upgrade immutable item/context mismatch: " + ",".join(conflicts),
            file=sys.stderr,
        )
        raise SystemExit(2)
    ctx = {**item, **{k: v for k, v in ctx.items() if k != "item"}}

live = os.environ.get("LOOM_CANARY_LIVE") == "1" or os.environ.get("LOOM_LIVE") == "1"
cand = str(ctx.get("candidate") or "")
cand_cli = str(ctx.get("candidate_cli") or "")
version = str(ctx.get("version") or "")
lastdbd_version = str(ctx.get("lastdbd_version") or "")
lastdb_version = str(ctx.get("lastdb_version") or "")
lastdbd_sha256 = str(ctx.get("lastdbd_sha256") or "")
lastdb_sha256 = str(ctx.get("lastdb_sha256") or "")
source_git_oid = str(ctx.get("source_git_oid") or "")
candidate_artifact_digest = str(ctx.get("candidate_artifact_digest") or "")
safe_upgrade_protocol_version = str(ctx.get("safe_upgrade_protocol_version") or "")


def emit(payload, line="PASS"):
    print("LOOM_CONTEXT_PATCH:" + json.dumps(payload, separators=(",", ":")))
    print(line)
    print("PASS")


def node_timeout(node):
    graph_path = os.environ.get("LOOM_SAFE_UPGRADE_GRAPH") or ""
    if not graph_path or not os.path.isfile(graph_path):
        raise RuntimeError(f"safe-upgrade graph missing: {graph_path}")
    with open(graph_path, encoding="utf-8") as handle:
        graph = json.load(handle)
    value = graph.get("states", {}).get(node, {}).get("timeout_sec")
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise RuntimeError(f"safe-upgrade graph has invalid {node} timeout: {value}")
    return value


def binary_version(path):
    try:
        proc = subprocess.run(
            [path, "--version"], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    fields = (proc.stdout or "").strip().split()
    return fields[-1] if proc.returncode == 0 and fields else ""


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify_candidate_binding():
    required = {
        "candidate": cand,
        "candidate_cli": cand_cli,
        "version": version,
        "lastdbd_version": lastdbd_version,
        "lastdb_version": lastdb_version,
        "lastdbd_sha256": lastdbd_sha256,
        "lastdb_sha256": lastdb_sha256,
        "source_git_oid": source_git_oid,
        "candidate_artifact_digest": candidate_artifact_digest,
        "safe_upgrade_protocol_version": safe_upgrade_protocol_version,
    }
    missing = [name for name, value in required.items() if not value]
    if missing:
        return False, "candidate binding is missing: " + ",".join(missing)
    if not re.fullmatch(r"[0-9a-f]{40}", source_git_oid):
        return False, "candidate source Git OID is not one full lowercase commit"
    if safe_upgrade_protocol_version != "6":
        return False, "safe-upgrade protocol version is not 6"
    if not re.fullmatch(r"[0-9a-f]{64}", lastdbd_sha256) or not re.fullmatch(
        r"[0-9a-f]{64}", lastdb_sha256
    ):
        return False, "candidate binding has an invalid SHA-256"
    if not re.fullmatch(r"[0-9a-f]{64}", candidate_artifact_digest):
        return False, "candidate artifact digest is not one SHA-256"
    actual_artifact_digest = hashlib.sha256(
        "\0".join(
            [
                source_git_oid,
                cand,
                cand_cli,
                lastdbd_sha256,
                lastdb_sha256,
                lastdbd_version,
                lastdb_version,
            ]
        ).encode()
    ).hexdigest()
    if actual_artifact_digest != candidate_artifact_digest:
        return False, "candidate artifact digest does not match the immutable tuple"
    try:
        daemon_real = str(Path(cand).expanduser().resolve(strict=True))
        cli_real = str(Path(cand_cli).expanduser().resolve(strict=True))
    except OSError as error:
        return False, f"candidate binding path cannot resolve: {error}"
    if daemon_real != cand or cli_real != cand_cli:
        return False, "candidate binding paths are not canonical"
    if Path(cli_real).parent != Path(daemon_real).parent or Path(cli_real).name != "lastdb":
        return False, "candidate CLI is not the sibling lastdb binary"
    if not os.access(daemon_real, os.X_OK) or not os.access(cli_real, os.X_OK):
        return False, "candidate pair is not executable"
    actual_daemon_version = binary_version(daemon_real)
    actual_cli_version = binary_version(cli_real)
    if (
        not actual_daemon_version
        or actual_daemon_version != version
        or actual_daemon_version != lastdbd_version
        or actual_cli_version != lastdb_version
        or actual_cli_version != actual_daemon_version
    ):
        return False, "candidate pair version changed after Loom kickoff"
    try:
        actual_daemon_sha = file_sha256(daemon_real)
        actual_cli_sha = file_sha256(cli_real)
    except OSError as error:
        return False, f"candidate pair cannot be hashed: {error}"
    if actual_daemon_sha != lastdbd_sha256 or actual_cli_sha != lastdb_sha256:
        return False, "candidate pair bytes changed after Loom kickoff"
    return True, "exact candidate pair matches Loom context"


def exact_driver_env():
    env = os.environ.copy()
    env.update(
        {
            "LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID": source_git_oid,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH": cand,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH": cand_cli,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION": lastdbd_version,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION": lastdb_version,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256": lastdbd_sha256,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256": lastdb_sha256,
        }
    )
    receipt_root = os.environ.get("LASTDB_DEV_STAMP_ROOT") or os.path.expanduser(
        "~/.local/state/last-stack/lastdb-safe-upgrade/dev-photograph-receipts"
    )
    exec_id = os.environ.get("LOOM_EXEC_ID") or ""
    safe_exec_id = re.sub(r"[^A-Za-z0-9._-]", "_", exec_id)
    env["LASTDB_DEV_STAMP_RECEIPT"] = os.path.join(
        receipt_root,
        f"{safe_exec_id}-{lastdbd_sha256[:16]}-{lastdb_sha256[:16]}.receipt",
    )
    return env


def check_freshness():
    script = os.environ.get("LOOM_LASTDB_FRESHNESS_SCRIPT") or ""
    if not script or not os.path.isfile(script):
        return {
            "ok": False,
            "relation": "unknown",
            "reason": f"freshness helper missing: {script}",
        }
    cmd = [sys.executable, script, "--candidate", cand]
    if version:
        cmd.extend(["--candidate-version", version])
    if source_git_oid:
        cmd.extend(["--candidate-source-oid", source_git_oid])
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    lines = [line for line in (p.stdout or "").splitlines() if line.strip()]
    try:
        result = json.loads(lines[-1]) if lines else {}
    except json.JSONDecodeError:
        result = {}
    if not isinstance(result, dict):
        result = {}
    result.setdefault("ok", False)
    result.setdefault("relation", "unknown")
    result.setdefault(
        "reason",
        (p.stderr or "").strip() or f"freshness helper returned rc={p.returncode}",
    )
    print(
        "safe-upgrade freshness "
        f"relation={result['relation']} reason={result['reason']}"
    )
    return result


if not live:
    if step == "PROBE":
        v = os.environ.get("SAFE_UPGRADE_PROBE_VERDICT") or "green"
        emit({"verdict": v, "candidate": cand}, f"su PROBE stand-in verdict={v}")
    elif step == "CUTOVER":
        print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"stand-in-cutover"}')
        print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"stand-in-cutover"}')
        emit({"cutover": "stand-in", "verdict": "green"}, "su CUTOVER stand-in")
    elif step == "VERIFY":
        emit({"verify": "stand-in"}, "su VERIFY stand-in")
    else:
        sys.stderr.write(f"unknown step {step}\n")
        sys.exit(2)
    raise SystemExit(0)

skill = os.path.expanduser(
    "~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
)


def evidence_tail(text, limit=2000):
    lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
    return "\n".join(lines[-30:])[-limit:]


def probe_failure_reason(text, final_verdict, rc):
    # The die() line prints only when lock acquisition terminally failed, so
    # this cannot fire on a run that waited, acquired, and then failed a bar.
    if "owns the host-wide safety lane" in text:
        return (
            "safe-upgrade owner lock busy past the wait budget — "
            "harness contention, not a candidate defect"
        )
    reasons = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("REASON:")]
    if reasons:
        return reasons[-1][:400]
    if final_verdict:
        return f"{final_verdict} (rc={rc})"
    return f"driver exited rc={rc} with no VERDICT line"


def write_evidence_file(stage, text, rc):
    """Persist driver output next to the staged candidate.

    Loom keeps no output for a failed node, so without this file a RED
    cutover leaves zero evidence (heal lx-20260830T195506 started blind).
    Best effort: evidence must never turn a probe verdict into a crash.
    """
    if not cand:
        return
    try:
        path = os.path.join(
            os.path.dirname(cand),
            f"{stage}-fail-{os.environ.get('LOOM_EXEC_ID') or 'loom-unknown'}.log",
        )
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(f"stage={stage} rc={rc}\n")
            handle.write(text)
        print(f"su {stage} evidence: {path}", file=sys.stderr)
    except OSError as err:
        print(f"su {stage} evidence write failed: {err}", file=sys.stderr)

if step == "PROBE":
    if not cand:
        emit({"verdict": "red"}, "su PROBE no candidate")
        raise SystemExit(0)
    bound, binding_reason = verify_candidate_binding()
    if not bound:
        emit(
            {"verdict": "red", "last_error": binding_reason},
            "su PROBE exact candidate binding refused",
        )
        raise SystemExit(0)
    freshness = check_freshness()
    relation = str(freshness.get("relation") or "unknown")
    if freshness.get("ok") and relation == "current":
        emit(
            {"verdict": "current", "freshness": relation},
            "su PROBE candidate already current",
        )
        raise SystemExit(0)
    if not freshness.get("ok") or relation != "forward":
        emit(
            {
                "verdict": "red",
                "freshness": relation,
                "last_error": str(freshness.get("reason") or "ancestry unproved"),
            },
            f"su PROBE freshness={relation} refused",
        )
        raise SystemExit(0)
    # Loom can re-dispatch a long PROBE after its caller reaches the drive
    # deadline. The immutable execution context already contains the exact
    # prior result. Reuse only a clean GREEN result after the current
    # freshness check. CUTOVER runs the complete safe-upgrade driver again,
    # so this skips no live safety gate.
    if (
        ctx.get("verdict") == "green"
        and type(ctx.get("probe_rc")) is int
        and ctx.get("probe_rc") == 0
        and not ctx.get("last_error")
    ):
        # Do not write the same context patch again. The new revision can race
        # the state advance and leave PROBE selected for another dispatch.
        print("su PROBE reused exact stored green result")
        print("PASS")
        raise SystemExit(0)
    # A re-dispatched PROBE can find the owner lock still held by an earlier
    # attempt's orphaned process tree. Wait for the lane instead of marking
    # the candidate RED; the budget stays well under the PROBE node timeout.
    probe_env = exact_driver_env()
    probe_env.setdefault("LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S", "2700")
    p = subprocess.run(
        ["bash", skill, "--candidate", cand, "--probe-only"],
        capture_output=True, text=True, timeout=node_timeout("PROBE"), env=probe_env,
    )
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    text = (p.stdout or "") + (p.stderr or "")
    # The driver cats sub-probe output (smoke prints its own "VERDICT: GREEN"),
    # so a substring match false-greens a red probe: rc=1 runs reached CUTOVER
    # on lx-20260830T203912.259-78723-1. Only the driver's FINAL verdict line
    # plus rc==0 is green.
    verdicts = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("VERDICT:")]
    final_verdict = verdicts[-1] if verdicts else ""
    green = p.returncode == 0 and final_verdict in (
        "VERDICT: GREEN",
        "VERDICT: GREEN_PROBE_ONLY",
    )
    patch = {"verdict": "green" if green else "red", "probe_rc": p.returncode}
    if not green:
        patch["last_error"] = probe_failure_reason(text, final_verdict, p.returncode)
        patch["probe_tail"] = evidence_tail(text)
        write_evidence_file("probe", text, p.returncode)
    emit(patch, f"su PROBE verdict={patch['verdict']}")
    raise SystemExit(0)

if step == "CUTOVER":
    bound, binding_reason = verify_candidate_binding()
    if not bound:
        sys.stderr.write(f"safe-upgrade CUTOVER refused: {binding_reason}\n")
        raise SystemExit(1)
    freshness = check_freshness()
    relation = str(freshness.get("relation") or "unknown")
    if freshness.get("ok") and relation == "current":
        emit(
            {"cutover": "already-current", "verdict": "green", "freshness": relation},
            "su CUTOVER candidate became current; no live change",
        )
        raise SystemExit(0)
    if not freshness.get("ok") or relation != "forward":
        sys.stderr.write(
            "safe-upgrade CUTOVER refused: "
            f"freshness={relation} reason={freshness.get('reason') or 'ancestry unproved'}\n"
        )
        raise SystemExit(1)
    print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"lastdb-safe-upgrade"}')
    cutover_env = exact_driver_env()
    cutover_env["LASTDB_SAFE_UPGRADE_VIA_LOOM"] = "1"
    cutover_env.setdefault("LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S", "1800")
    p = subprocess.run(
        ["bash", skill, "--candidate", cand, "--yes"],
        capture_output=True, text=True, timeout=node_timeout("CUTOVER"), env=cutover_env,
    )
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    if p.returncode != 0:
        write_evidence_file("cutover", (p.stdout or "") + (p.stderr or ""), p.returncode)
        sys.exit(p.returncode)
    print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"lastdb-safe-upgrade"}')
    emit({"cutover": "live", "verdict": "green"}, "su CUTOVER live")
    raise SystemExit(0)

if step == "VERIFY":
    p = subprocess.run(["kanban", "list", "--column", "todo"], capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        sys.stderr.write(p.stderr or "")
        sys.exit(p.returncode)
    emit({"verify": "live"}, "su VERIFY live")
    raise SystemExit(0)

sys.stderr.write(f"unknown live step {step}\n")
sys.exit(2)
PY
