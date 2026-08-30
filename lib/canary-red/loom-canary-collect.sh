#!/usr/bin/env bash
# COLLECT node: read the failed lastdb-canary-release execution and its
# safe-upgrade child from loom's own records. Effects: none. Never mutates
# the primary.
set -euo pipefail

python3 <<'PY'
import json, os, subprocess, sys
from datetime import datetime, timezone

raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

max_attempts = ctx.get("max_attempts")
if max_attempts is None:
    max_attempts = os.environ.get("LAST_STACK_CANARY_RED_MAX_ATTEMPTS", "3")
try:
    max_attempts = int(max_attempts)
except (TypeError, ValueError):
    max_attempts = 3
if max_attempts < 1:
    max_attempts = 3

exec_id = str(ctx.get("exec_id") or os.environ.get("CANARY_RED_EXEC_ID") or "").strip()
fixture = (
    os.environ.get("CANARY_RED_LOOM_GET_FILE")
    or os.environ.get("CANARY_RED_SM_GET_FILE")
    or ""
)


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def exec_latest_bin():
    """Locate the loom execution reader.

    The gate puts the install's bin/ on PATH, but a node command re-execed by
    loom may not inherit it, so fall back to the shipped tree.
    """
    from shutil import which

    hit = which("last-stack-loom-exec-latest")
    if hit:
        return hit
    for root in (
        os.environ.get("LAST_STACK_ROOT") or "",
        os.path.join(os.path.expanduser("~"), ".last-stack"),
    ):
        cand = os.path.join(root, "bin", "last-stack-loom-exec-latest")
        if root and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return ""


def loom_get(exec_id):
    """Read one loom execution and normalize it to the row shape below.

    The canary lane is orchestrated by loom. `sm` holds a retired copy that
    stopped issuing ids on 2026-08-26 and cannot resolve an `lx-*` id at all,
    so reading it here failed COLLECT on every live red
    (papercut-canary-red-heal-collect-reads-retired-sm-not-loom).
    """
    binpath = exec_latest_bin()
    if not binpath:
        return None, "last-stack-loom-exec-latest not found on PATH or in LAST_STACK_ROOT/bin"
    try:
        p = subprocess.run(
            [binpath, "--exec", exec_id, "--full"],
            capture_output=True,
            text=True,
            timeout=60,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    if p.returncode != 0:
        return None, (p.stderr or p.stdout or "loom exec read failed").strip()
    try:
        rows = json.loads(p.stdout)
    except json.JSONDecodeError:
        return None, "loom exec read returned non-json"
    if not isinstance(rows, list) or not rows:
        return None, f"execution not found in loom records: {exec_id}"
    row = rows[0]
    if not isinstance(row, dict):
        return None, "loom exec row is not an object"
    # loom's column names -> the names the rest of this node reads.
    return {
        "id": row.get("id") or row.get("exec_id") or exec_id,
        "status": row.get("status") or "",
        "state": row.get("state") or "",
        "contextJson": row.get("hot_context_patch_json") or "",
        "inputJson": row.get("input_json") or "",
        "lastError": row.get("last_error") or "",
        "parent_execution_id": row.get("parent_execution_id") or "",
    }, ""


def ctx_obj(row):
    if not isinstance(row, dict):
        return {}
    raw_ctx = row.get("contextJson") or row.get("context") or {}
    if isinstance(raw_ctx, str):
        try:
            raw_ctx = json.loads(raw_ctx)
        except json.JSONDecodeError:
            raw_ctx = {}
    return raw_ctx if isinstance(raw_ctx, dict) else {}


row = None
err = ""
if fixture:
    try:
        row = load_json(fixture)
    except Exception as e:
        print(f"canary-collect: fixture failed: {e}", file=sys.stderr)
        sys.exit(1)
elif exec_id:
    row, err = loom_get(exec_id)
    if row is None:
        print(f"canary-collect: loom get failed: {err}", file=sys.stderr)
        sys.exit(1)

if not isinstance(row, dict):
    row = {}

status = str(row.get("status") or "")
state = str(row.get("state") or "")
exec_id = str(row.get("id") or exec_id or "")
parent_ctx = ctx_obj(row)
child_id = str(
    parent_ctx.get("__child_UPGRADE")
    or (f"{exec_id}-UPGRADE" if exec_id else "")
)
if child_id and not child_id.startswith("exec_"):
    child_id = f"exec_{child_id}" if not exec_id else child_id

child = {}
if fixture:
    child_fix = (
        os.environ.get("CANARY_RED_LOOM_CHILD_FILE")
        or os.environ.get("CANARY_RED_SM_CHILD_FILE")
        or ""
    )
    if child_fix:
        try:
            child = load_json(child_fix)
        except Exception:
            child = {}
elif child_id:
    # A missing child is not fatal: the parent row already carries the
    # verdict, and the child only enriches probe_tail / candidate.
    child, _ = loom_get(child_id)
    if not isinstance(child, dict):
        child = {}

child_ctx = ctx_obj(child)
probe_tail = str(
    child_ctx.get("probe_stdout_tail")
    or parent_ctx.get("probe_stdout_tail")
    or ""
)
last_error = str(
    child_ctx.get("last_error")
    or row.get("lastError")
    or row.get("last_error")
    or ""
)
oid = str(
    parent_ctx.get("source_git_oid")
    or ""
)
if not oid:
    inj = row.get("inputJson") or row.get("input") or {}
    if isinstance(inj, str):
        try:
            inj = json.loads(inj)
        except json.JSONDecodeError:
            inj = {}
    if isinstance(inj, dict):
        oid = str(inj.get("main_oid") or "")
version = str(parent_ctx.get("version") or "")
candidate = str(
    parent_ctx.get("candidate")
    or child_ctx.get("candidate")
    or ""
)

verdict = "idle"
if exec_id and status in ("failed", "error"):
    verdict = "red"
elif exec_id and status in ("succeeded", "succeed"):
    verdict = "green"
elif not exec_id:
    verdict = "idle"

# Attempt is the number of heal+retry cycles already finished.
attempt = ctx.get("attempt")
if attempt is None:
    attempt = 0
try:
    attempt = int(attempt)
except (TypeError, ValueError):
    attempt = 0

patch = {
    "exec_id": exec_id,
    "child_id": str(child.get("id") or child_id or ""),
    "status": status,
    "state": state,
    "source_git_oid": oid,
    "version": version,
    "candidate": candidate,
    "last_error": last_error[:500],
    "probe_tail": probe_tail[-4000:],
    "attempt": attempt,
    "max_attempts": max_attempts,
    "verdict": verdict,
    "collected_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
print("LOOM_CONTEXT_PATCH:" + json.dumps(patch, separators=(",", ":")))
print(
    f"canary-collect exec={exec_id or '-'} status={status or '-'} "
    f"verdict={verdict} oid={oid[:12] or '-'}"
)
print("PASS")
PY
