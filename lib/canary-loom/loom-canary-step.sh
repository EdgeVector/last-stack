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
        emit({"build_next": "BUILD_COLLECT"}, "canary-step BUILD_POLL stand-in")
    elif step == "BUILD_COLLECT":
        oid = str(ctx.get("main_oid") or "stand-in")
        emit(
            {
                "candidate": "/tmp/stand-in-lastdbd",
                "source_git_oid": oid,
                "version": "stand-in",
                "build_next": "PROBE",
            },
            "canary-step BUILD_COLLECT stand-in",
        )
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
        emit({"soak_status": soak}, f"canary-step SOAK stand-in status={soak}")
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
    for line in (stdout or "").splitlines():
        if line.startswith("SM_CONTEXT_PATCH:"):
            print("LOOM_CONTEXT_PATCH:" + line[len("SM_CONTEXT_PATCH:") :])
        else:
            print(line)


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
    translate_sm(p.stdout)
    if p.stderr:
        sys.stderr.write(p.stderr)
    if p.returncode != 0:
        sys.exit(p.returncode)
    print("PASS")
    raise SystemExit(0)

if step == "PROBE":
    cand = str(ctx.get("candidate") or "")
    if not cand:
        emit({"verdict": "red", "last_error": "no candidate"}, "canary-step PROBE no candidate")
        raise SystemExit(0)
    skill = os.path.expanduser(
        "~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
    )
    p = run(["bash", skill, "--candidate", cand, "--probe-only"], timeout=7200)
    text = (p.stdout or "") + "\n" + (p.stderr or "")
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    verdict = "green" if "VERDICT: GREEN" in text or "VERDICT: GREEN_PROBE_ONLY" in text else "red"
    if exhausted() and verdict == "red":
        verdict = "exhausted"
    emit({"verdict": verdict, "probe_rc": p.returncode}, f"canary-step PROBE verdict={verdict}")
    raise SystemExit(0)

if step == "CUTOVER":
    cand = str(ctx.get("candidate") or "")
    skill = os.path.expanduser(
        "~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
    )
    print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"lastdb-safe-upgrade"}')
    p = run(["bash", skill, "--candidate", cand, "--yes"], timeout=3600)
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    if p.returncode != 0:
        sys.exit(p.returncode)
    print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"lastdb-safe-upgrade"}')
    emit({"cutover": "live"}, "canary-step CUTOVER live")
    raise SystemExit(0)

if step == "VERIFY":
    p = run(["kanban", "list", "--column", "todo"], timeout=120)
    if p.returncode != 0:
        sys.stderr.write(p.stderr or "")
        sys.exit(p.returncode)
    emit({"verify": "live"}, "canary-step VERIFY live")
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
