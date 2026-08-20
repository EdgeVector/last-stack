#!/usr/bin/env bash
# HEAL node: one EV OPS "What's wrong" exception.
# Default is a contract stand-in (CI / cargo test). LOOM_WHATS_WRONG_LIVE=1
# (or LOOM_LIVE=1) runs grok/claude against the host with hard Last Stack
# guardrails. Never restarts primary lastdbd.
set -euo pipefail

python3 <<'PY'
import json, os, shutil, subprocess, sys, tempfile, textwrap

raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

item = ctx.get("item")
if isinstance(item, str):
    try:
        item = json.loads(item)
    except json.JSONDecodeError:
        item = {"id": item, "label": item, "why": item}
if not isinstance(item, dict):
    item = {}

exc_id = str(item.get("id") or "unknown")
label = str(item.get("label") or exc_id)
why = str(item.get("why") or item.get("detail") or "")
dashboard = str(ctx.get("dashboard") or os.environ.get("WHATS_WRONG_DASHBOARD") or "http://127.0.0.1:7733")
live = os.environ.get("LOOM_WHATS_WRONG_LIVE") == "1" or os.environ.get("LOOM_LIVE") == "1"

def emit(payload, line):
    print("LOOM_CONTEXT_PATCH:" + json.dumps(payload, separators=(",", ":")))
    print(line)
    print("PASS")

if not live:
    emit(
        {
            "id": exc_id,
            "label": label,
            "heal_status": "stand-in",
            "papercut": "",
            "evidence": "LOOM_WHATS_WRONG_LIVE unset; no host mutation",
        },
        f"whats-wrong-heal stand-in id={exc_id}",
    )
    sys.exit(0)

agent = None
for cand in ("grok", "claude"):
    if shutil.which(cand):
        agent = cand
        break
if not agent:
    print("loom-whats-wrong-heal: grok/claude not on PATH", file=sys.stderr)
    sys.exit(2)

cwd = os.environ.get("WHATS_WRONG_CWD") or os.path.expanduser("~/code/edgevector")
prompt = textwrap.dedent(f"""
You are ONE heal agent for a single EV OPS dashboard exception.

Dashboard: {dashboard}/  (What's wrong panel = coverage.exceptions)
Exception JSON:
{json.dumps(item, indent=2)}

Goal: make this row leave coverage.exceptions. Diagnose, then apply a
bounded mechanical fix if one exists. If you cannot finish this wake,
file or update a Brain papercut (never a kanban card).

Hard guardrails:
- NEVER restart, kill, or reset the primary LastDB node (lastdbd on ~/.lastdb).
  A busy node is not a dead node. :9001 refused is not an outage.
- NEVER kickstart/restart Forgejo or the primary forge-run agent.
- NEVER git add -A / stash / reset in a shared checkout. Isolated worktrees only.
- NEVER --admin / force-merge LastGit. NEVER invent North Stars or bulk-file cards.
- Disk / LastDB volume: run last-stack-disk-reclaim helpers only. Do not delete
  ~/.lastdb, backups, or anything whose realpath is inside the primary home.
- why-stopped-loom stale: inspect the loom stamp and last-stack-why-stopped-loom
  --status; do not restart lastdbd to clear it.
- Schema doctor "degraded": file a papercut; do not re-register schemas unattended.

Papercuts:
  brain papercut file papercut-whats-wrong-<id-kebab> --component ops-terminal \\
    --symptom "<one line>" --title "<what is wrong>" --severity p1 \\
    --body "<exception json, evidence, repro, suggested fix>"
Search first (brain ask / brain get). Update in place. If you healed it this
wake, close with evidence of a live check you ran.

When done, print exactly one line that starts with HEAL_RESULT and a JSON
object, then stop:
HEAL_RESULT {{"id":"{exc_id}","heal_status":"healed|papercut|blocked|noop","papercut":"<slug-or-empty>","evidence":"<one line>"}}
""").strip()

prompt_file = tempfile.NamedTemporaryFile("w", prefix="whats-wrong-heal-", suffix=".md", delete=False)
prompt_file.write(prompt)
prompt_file.close()

if agent == "grok":
    cmd = [
        "grok",
        "--always-approve",
        "--permission-mode", "acceptEdits",
        "--cwd", cwd,
        "--prompt-file", prompt_file.name,
    ]
else:
    cmd = ["claude", "-p", prompt, "--dangerously-skip-permissions"]

try:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=700)
except subprocess.TimeoutExpired:
    emit(
        {
            "id": exc_id,
            "label": label,
            "heal_status": "blocked",
            "papercut": "",
            "evidence": "heal agent timed out",
        },
        f"whats-wrong-heal timeout id={exc_id}",
    )
    sys.exit(0)
except FileNotFoundError:
    print(f"loom-whats-wrong-heal: {agent} not executable", file=sys.stderr)
    sys.exit(2)
finally:
    try:
        os.unlink(prompt_file.name)
    except OSError:
        pass

out = (proc.stdout or "") + "\n" + (proc.stderr or "")
payload = {
    "id": exc_id,
    "label": label,
    "heal_status": "blocked" if proc.returncode else "noop",
    "papercut": "",
    "evidence": f"agent_exit={proc.returncode}",
}
for line in out.splitlines():
    if not line.startswith("HEAL_RESULT"):
        continue
    rest = line[len("HEAL_RESULT"):].strip()
    try:
        parsed = json.loads(rest)
    except json.JSONDecodeError:
        continue
    if isinstance(parsed, dict):
        payload.update({k: parsed[k] for k in ("id", "heal_status", "papercut", "evidence") if k in parsed})
        break

emit(payload, f"whats-wrong-heal id={payload.get('id')} status={payload.get('heal_status')}")
PY
