#!/usr/bin/env bash
# RETRY node: after a landed fix, start a new canary upgrade through sm.
# Stand-in unless LOOM_LIVE=1. Never live-cutover on a RED probe — sm's
# lastdb-safe-upgrade child already refuses that.
set -euo pipefail

python3 <<'PY'
import json, os, subprocess, sys, time

raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

live = os.environ.get("LOOM_CANARY_RED_LIVE") == "1" or os.environ.get("LOOM_LIVE") == "1"
attempt = ctx.get("attempt") or 0
try:
    attempt = int(attempt)
except (TypeError, ValueError):
    attempt = 0
max_attempts = ctx.get("max_attempts") or 3
try:
    max_attempts = int(max_attempts)
except (TypeError, ValueError):
    max_attempts = 3

heal_status = str(ctx.get("heal_status") or "")
old_oid = str(ctx.get("source_git_oid") or "")
merge_sha = str(ctx.get("merge_sha") or "").strip()
failed_exec = str(ctx.get("exec_id") or "")
next_attempt = attempt + 1


def emit(payload, line, code=0):
    print("LOOM_CONTEXT_PATCH:" + json.dumps(payload, separators=(",", ":")))
    print(line)
    print(json.dumps(payload, separators=(",", ":")))
    sys.exit(code)


def sm_json(args, timeout=60):
    try:
        p = subprocess.run(
            ["sm", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    text = (p.stdout or "") + (p.stderr or "")
    if p.returncode != 0:
        return None, text.strip() or "sm failed"
    try:
        return json.loads(p.stdout), ""
    except json.JSONDecodeError:
        return {"raw": p.stdout.strip()}, ""


def verdict_after_no_upgrade(reason):
    if heal_status in ("blocked", "noop"):
        v = "blocked" if heal_status == "blocked" else "idle"
    elif next_attempt >= max_attempts:
        v = "exhausted"
    else:
        v = "red"
    return {
        "attempt": next_attempt,
        "verdict": v,
        "retry_reason": reason,
        "retry_exec_id": "",
    }


if not live:
    stub = os.environ.get("CANARY_RED_RETRY_VERDICT") or ""
    if stub:
        v = stub
    elif heal_status in ("blocked", "noop"):
        v = "blocked" if heal_status == "blocked" else "idle"
    elif next_attempt >= max_attempts:
        v = "exhausted"
    else:
        v = "red"
    payload = {
        "attempt": next_attempt,
        "verdict": v,
        "retry_reason": "stand-in",
        "retry_exec_id": "",
    }
    print(f'LOOM_EFFECT_INTENT:{{"kind":"none","target":"stand-in"}}')
    print(f'LOOM_EFFECT_DONE:{{"kind":"none","target":"stand-in"}}')
    emit(payload, f"canary-retry stand-in attempt={next_attempt} verdict={v}")

if heal_status not in ("fixed",):
    payload = verdict_after_no_upgrade(f"heal_status={heal_status or 'empty'}")
    emit(
        payload,
        f"canary-retry skip-upgrade attempt={next_attempt} verdict={payload['verdict']}",
    )

new_oid = merge_sha
if not new_oid:
    payload = verdict_after_no_upgrade("no merge_sha from heal")
    emit(
        payload,
        f"canary-retry skip-upgrade attempt={next_attempt} verdict={payload['verdict']}",
    )

if old_oid and new_oid.startswith(old_oid[:12]):
    payload = verdict_after_no_upgrade("merge_sha still the failed oid")
    emit(
        payload,
        f"canary-retry same-oid attempt={next_attempt} verdict={payload['verdict']}",
    )

# Fence: do not start a canary cutover while a long job blocks safe-upgrade.
try:
    pre = subprocess.run(
        [
            "situations",
            "preflight",
            "--action",
            "lastdb-safe-upgrade",
            "--repo",
            "EdgeVector/fold",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    if pre.returncode not in (0,):
        payload = {
            "attempt": attempt,  # do not burn a retry on a fence
            "verdict": "blocked",
            "retry_reason": f"situation fence rc={pre.returncode}",
            "retry_exec_id": "",
        }
        emit(
            payload,
            f"canary-retry fence-blocked rc={pre.returncode}",
        )
except FileNotFoundError:
    pass

key = f"canary-{new_oid}"
start_input = json.dumps({"main_oid": new_oid}, separators=(",", ":"))
print(f'LOOM_EFFECT_INTENT:{{"kind":"deploy","target":"{key}"}}')
started, err = sm_json(
    [
        "start",
        "lastdb-canary-release",
        "--input",
        start_input,
        "--idempotency-key",
        key,
        "--concurrency-key",
        "lastdb-canary-release",
        "--json",
    ],
    timeout=60,
)
if started is None:
    payload = verdict_after_no_upgrade(f"sm start failed: {err[:200]}")
    emit(
        payload,
        f"canary-retry start-failed attempt={next_attempt} verdict={payload['verdict']}",
    )

retry_id = ""
if isinstance(started, dict):
    retry_id = str(started.get("id") or started.get("executionId") or "")
    if not retry_id and isinstance(started.get("raw"), str):
        retry_id = started["raw"].split()[0] if started["raw"].split() else ""

# Tick until the child upgrade terminals or the budget is gone.
deadline = time.time() + int(os.environ.get("CANARY_RED_RETRY_TICK_SEC", "6900"))
last_status = ""
last_state = ""
while time.time() < deadline:
    subprocess.run(
        ["sm", "tick", "--definition", "lastdb-canary-release", "--cap", "4"],
        capture_output=True,
        text=True,
        timeout=120,
    )
    row, _ = sm_json(["get", retry_id, "--json"] if retry_id else ["list", "--definition", "lastdb-canary-release", "--json"], timeout=30)
    rec = row
    if isinstance(row, list):
        rec = next((r for r in row if str(r.get("id") or "") == retry_id), row[0] if row else {})
    if not isinstance(rec, dict):
        rec = {}
    last_status = str(rec.get("status") or "")
    last_state = str(rec.get("state") or "")
    if last_status in ("succeeded", "failed", "cancelled"):
        break
    time.sleep(20)

if last_status == "succeeded":
    verdict = "green"
    reason = "canary upgrade GREEN"
elif last_status == "failed":
    verdict = "exhausted" if next_attempt >= max_attempts else "red"
    reason = f"canary upgrade RED state={last_state}"
else:
    verdict = "red" if next_attempt < max_attempts else "exhausted"
    reason = f"tick budget ended status={last_status or 'unknown'} state={last_state}"

payload = {
    "attempt": next_attempt,
    "verdict": verdict,
    "retry_reason": reason,
    "retry_exec_id": retry_id,
    "source_git_oid": new_oid,
}
print(f'LOOM_EFFECT_DONE:{{"kind":"deploy","target":"{retry_id or key}"}}')
emit(payload, f"canary-retry attempt={next_attempt} verdict={verdict} exec={retry_id or '-'}")
PY
