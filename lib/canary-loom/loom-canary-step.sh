#!/usr/bin/env bash
# Deterministic steps for lastdb-canary-release. Default stand-in (CI / proof).
# LOOM_LIVE=1 or LOOM_CANARY_LIVE=1 calls the real build / safe-upgrade / soak
# helpers. Never decides GREEN in an LLM.
set -euo pipefail
step="${1:?step name required}"

python3 - "$step" <<'PY'
import json, os, subprocess, sys

step = sys.argv[1]
raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

live = os.environ.get("LOOM_CANARY_LIVE") == "1" or os.environ.get("LOOM_LIVE") == "1"
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


def emit(payload, line="PASS"):
    print("LOOM_CONTEXT_PATCH:" + json.dumps(payload, separators=(",", ":")))
    print(line)
    print("PASS")


def exhausted():
    return attempt >= max_attempts


def next_revision(name):
    current = ctx.get(name) or 0
    try:
        current = int(current)
    except (TypeError, ValueError):
        current = 0
    return current + 1


if not live:
    if step == "BUILD_START":
        emit(
            {
                "build_next": "BUILD_COLLECT",
                "attempt": attempt,
                "max_attempts": max_attempts,
            },
            "canary-step BUILD_START stand-in",
        )
    elif step == "BUILD_POLL":
        emit(
            {
                "build_next": "BUILD_COLLECT",
                "build_poll_revision": next_revision("build_poll_revision"),
            },
            "canary-step BUILD_POLL stand-in",
        )
    elif step == "BUILD_COLLECT":
        oid = str(ctx.get("main_oid") or "stand-in")
        job = {
            "candidate": "/tmp/stand-in-lastdbd",
            "source_git_oid": oid,
            "version": "stand-in",
        }
        emit(
            {
                **job,
                "upgrade_jobs": [job],
                "build_next": "CALL_A",
                "soak_started_at": "",
            },
            "canary-step BUILD_COLLECT stand-in",
        )
    elif step == "READ_A":
        emit({"child_status": "green"}, "canary-step READ_A stand-in child_status=green")
    elif step == "PROBE":
        forced = os.environ.get("CANARY_LOOM_PROBE_VERDICT") or ""
        verdict = forced or "green"
        if exhausted() and verdict == "red":
            verdict = "exhausted"
        emit({"verdict": verdict}, f"canary-step PROBE stand-in verdict={verdict}")
    elif step == "CUTOVER":
        print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"stand-in-cutover"}')
        print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"stand-in-cutover"}')
        emit({"cutover": "stand-in"}, "canary-step CUTOVER stand-in")
    elif step == "VERIFY":
        emit({"verify": "stand-in"}, "canary-step VERIFY stand-in")
    elif step == "SOAK":
        soak = os.environ.get("CANARY_LOOM_SOAK_STATUS") or "green"
        emit(
            {
                "soak_status": soak,
                "soak_hours": 24,
                "soak_poll_revision": next_revision("soak_poll_revision"),
            },
            f"canary-step SOAK stand-in status={soak}",
        )
    elif step == "RETRY_PREP":
        nxt = attempt + 1
        heal_status = str(ctx.get("heal_status") or "")
        if heal_status in ("blocked", "noop"):
            verdict = "blocked" if heal_status == "blocked" else "idle"
        elif nxt >= max_attempts:
            verdict = "exhausted"
        else:
            verdict = "red"
        emit(
            {"attempt": nxt, "verdict": verdict, "build_next": "BUILD_COLLECT"},
            f"canary-step RETRY_PREP stand-in attempt={nxt} verdict={verdict}",
        )
    elif step == "PROMOTE":
        print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"stand-in-promote"}')
        print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"stand-in-promote"}')
        emit({"promote": "stand-in"}, "canary-step PROMOTE stand-in")
    else:
        print(f"canary-step: unknown step {step}", file=sys.stderr)
        sys.exit(2)
    raise SystemExit(0)

# --- live path: wrap existing helpers; translate SM patches ---
def run(argv, timeout=120):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError as e:
        print(f"canary-step: missing {argv[0]}: {e}", file=sys.stderr)
        sys.exit(2)
    except subprocess.TimeoutExpired:
        print(f"canary-step: timeout {argv}", file=sys.stderr)
        sys.exit(1)
    return p


def translate_sm(stdout):
    merged = {}
    for line in (stdout or "").splitlines():
        if line.startswith("SM_CONTEXT_PATCH:"):
            raw_patch = line[len("SM_CONTEXT_PATCH:") :]
            try:
                merged.update(json.loads(raw_patch))
            except json.JSONDecodeError:
                pass
        else:
            print(line)
    return merged


if step == "READ_A":
    emit({"child_status": "green"}, "canary-step READ_A live assume join-all")
    raise SystemExit(0)

if step in ("BUILD_START", "BUILD_POLL", "BUILD_COLLECT", "SOAK", "PROMOTE"):
    env = os.environ.copy()
    env["SM_CONTEXT_JSON"] = json.dumps(ctx)
    env["SM_EXEC_ID"] = os.environ.get("LOOM_EXEC_ID") or "loom-unknown"
    sm_step = {
        "SOAK": "SOAK",
        "PROMOTE": "PROMOTE",
        "BUILD_START": "BUILD_START",
        "BUILD_POLL": "BUILD_POLL",
        "BUILD_COLLECT": "BUILD_COLLECT",
    }[step]
    p = subprocess.run(
        ["sm-canary-release-step", sm_step],
        capture_output=True,
        text=True,
        timeout=900 if step == "SOAK" else 3600 if step == "PROMOTE" else 300,
        env=env,
    )
    merged = translate_sm(p.stdout)
    if p.stderr:
        sys.stderr.write(p.stderr)
    if p.returncode != 0:
        sys.exit(p.returncode)
    patch = dict(merged)
    if step == "BUILD_POLL":
        patch["build_poll_revision"] = next_revision("build_poll_revision")
    elif step == "SOAK":
        patch["soak_poll_revision"] = next_revision("soak_poll_revision")
    if step == "BUILD_COLLECT":
        job = {
            "candidate": str(merged.get("candidate") or ctx.get("candidate") or ""),
            "source_git_oid": str(
                merged.get("source_git_oid") or ctx.get("source_git_oid") or ""
            ),
            "version": str(merged.get("version") or ctx.get("version") or ""),
        }
        patch["upgrade_jobs"] = [job]
    if patch:
        print(
            "LOOM_CONTEXT_PATCH:"
            + json.dumps(patch, separators=(",", ":"))
        )
    print("PASS")
    raise SystemExit(0)

if step == "RETRY_PREP":
    nxt = attempt + 1
    heal_status = str(ctx.get("heal_status") or "")
    if heal_status in ("blocked", "noop"):
        verdict = "blocked" if heal_status == "blocked" else "idle"
    elif nxt >= max_attempts:
        verdict = "exhausted"
    else:
        verdict = "red"
    emit(
        {"attempt": nxt, "verdict": verdict, "build_next": "BUILD_COLLECT"},
        f"canary-step RETRY_PREP attempt={nxt} verdict={verdict}",
    )
    raise SystemExit(0)

print(f"canary-step: unknown live step {step}", file=sys.stderr)
sys.exit(2)
PY
