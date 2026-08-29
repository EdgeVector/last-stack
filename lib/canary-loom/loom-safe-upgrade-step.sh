#!/usr/bin/env bash
# Graph A steps. Default stand-in. LOOM_LIVE=1 calls safe-upgrade-lastdb.sh.
set -euo pipefail
step="${1:?step}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
export LOOM_LASTDB_FRESHNESS_SCRIPT="${LOOM_LASTDB_FRESHNESS_SCRIPT:-$SCRIPT_DIR/lastdb-candidate-freshness.py}"
export LOOM_SAFE_UPGRADE_GRAPH="${LOOM_SAFE_UPGRADE_GRAPH:-$SCRIPT_DIR/lastdb-safe-upgrade.json}"

python3 - "$step" <<'PY'
import json, os, subprocess, sys

step = sys.argv[1]
raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

item = ctx.get("item")
if isinstance(item, dict):
    ctx = {**item, **{k: v for k, v in ctx.items() if k != "item"}}

live = os.environ.get("LOOM_CANARY_LIVE") == "1" or os.environ.get("LOOM_LIVE") == "1"
cand = str(ctx.get("candidate") or "")
version = str(ctx.get("version") or "")
source_git_oid = str(ctx.get("source_git_oid") or "")


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

if step == "PROBE":
    if not cand:
        emit({"verdict": "red"}, "su PROBE no candidate")
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
    p = subprocess.run(
        ["bash", skill, "--candidate", cand, "--probe-only"],
        capture_output=True, text=True, timeout=node_timeout("PROBE"),
    )
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    text = (p.stdout or "") + (p.stderr or "")
    v = "green" if "VERDICT: GREEN" in text or "GREEN_PROBE_ONLY" in text else "red"
    emit({"verdict": v, "probe_rc": p.returncode}, f"su PROBE verdict={v}")
    raise SystemExit(0)

if step == "CUTOVER":
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
    cutover_env = os.environ.copy()
    cutover_env["LASTDB_SAFE_UPGRADE_VIA_LOOM"] = "1"
    p = subprocess.run(
        ["bash", skill, "--candidate", cand, "--yes"],
        capture_output=True, text=True, timeout=node_timeout("CUTOVER"), env=cutover_env,
    )
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    if p.returncode != 0:
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
