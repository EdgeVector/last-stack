#!/usr/bin/env bash
# HEAL node: investigate the RED canary and LAND a fix.
# Default is a contract stand-in (CI). LOOM_LIVE=1 / LOOM_CANARY_RED_LIVE=1
# runs grok/claude. Do not file a kanban card and stop — merge a real change.
# Never restarts primary lastdbd. Never skips the probe latency bar.
set -euo pipefail

python3 <<'PY'
import json, os, shutil, subprocess, sys, tempfile, textwrap

raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

live = os.environ.get("LOOM_CANARY_RED_LIVE") == "1" or os.environ.get("LOOM_LIVE") == "1"
exec_id = str(ctx.get("exec_id") or "")
oid = str(ctx.get("source_git_oid") or "")
version = str(ctx.get("version") or "")
probe = str(ctx.get("probe_tail") or ctx.get("last_error") or "")
attempt = ctx.get("attempt") or 0
max_attempts = ctx.get("max_attempts") or 3
key = os.environ.get("LOOM_IDEMPOTENCY_KEY") or f"canary-red-{exec_id or 'unknown'}"


def emit(payload, line):
    print("LOOM_CONTEXT_PATCH:" + json.dumps(payload, separators=(",", ":")))
    print(line)
    print(json.dumps(payload, separators=(",", ":")))


if not live:
    payload = {
        "heal_status": "stand-in",
        "diagnosis": "LOOM_LIVE unset; no host mutation",
        "repo": "EdgeVector/fold",
        "pr_url": "",
        "merge_sha": "",
        "attempt": attempt,
    }
    print(f'LOOM_EFFECT_INTENT:{{"kind":"pr_open","target":"{key}"}}')
    print(f'LOOM_EFFECT_DONE:{{"kind":"pr_open","target":"{key}"}}')
    emit(payload, f"canary-heal stand-in exec={exec_id or '-'} attempt={attempt}")
    sys.exit(0)

agent = None
for cand in ("grok", "claude"):
    if shutil.which(cand):
        agent = cand
        break
if not agent:
    print("loom-canary-heal: grok/claude not on PATH", file=sys.stderr)
    sys.exit(2)

cwd = os.environ.get("CANARY_RED_CWD") or os.path.expanduser("~/code/edgevector")
prompt = textwrap.dedent(f"""
You are the LastDB canary RED healer. A canary upgrade failed. You RUN a fix.
You do not stop at a kanban card.

Failed execution: {exec_id or "(none)"}
Candidate oid: {oid or "(unknown)"}
Version: {version or "(unknown)"}
Heal attempt: {attempt} of {max_attempts}
Idempotency key / branch name: {key}

Probe / error evidence:
{probe or "(no probe tail)"}

Goal
1. Diagnose why the probe or soak is RED. Read the child safe-upgrade
   execution if you need more log. Do not guess past the evidence.
2. Land a real source change that can make the NEXT canary upgrade GREEN.
   Isolated worktree only. Commit, push, open the change request, and
   drive it to MERGED.
3. Print one HEAL_RESULT line when done.

Venue
- EdgeVector/fold is Forgejo (`last-stack-forge-git`, `last-stack-forge-api`).
- last-stack / loom / state-machine are LastGit (`lastgit cr`).
- Prefer fold when the RED is a binary/latency/RSS/correctness bar.
- Prefer last-stack when the RED is the probe harness itself.

Hard guardrails
- NEVER restart, kill, or reset the primary LastDB node (lastdbd on ~/.lastdb).
- NEVER `brew upgrade lastdb`. NEVER point a candidate at live ~/.lastdb.
- NEVER set LASTDB_PROBE_LAT_SKIP or LASTDB_PROBE_LAT_CORR_SKIP.
- NEVER git add -A / stash / reset in a shared checkout.
- NEVER file a kanban card as the only outcome. A card is extra, not the work.
- Situations: `situations preflight --action lastdb-safe-upgrade` if you
  think you need a live cutover. This node must not cut over.

When done, print exactly one line that starts with HEAL_RESULT and a JSON
object, then stop:
HEAL_RESULT {{"heal_status":"fixed|blocked|noop","repo":"<owner/name>","pr_url":"<url-or-empty>","merge_sha":"<full-sha-or-empty>","diagnosis":"<one line>"}}

heal_status meanings:
- fixed: a change merged; merge_sha is the new fold/last-stack tip to rebuild
- blocked: you cannot land a fix this wake (say why in diagnosis)
- noop: evidence is not a product defect (false red / already green)
""").strip()

prompt_file = tempfile.NamedTemporaryFile(
    "w", prefix="canary-red-heal-", suffix=".md", delete=False
)
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
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=3500)
except subprocess.TimeoutExpired:
    payload = {
        "heal_status": "blocked",
        "diagnosis": "heal agent timed out",
        "repo": "",
        "pr_url": "",
        "merge_sha": "",
        "attempt": attempt,
    }
    emit(payload, f"canary-heal timeout exec={exec_id or '-'}")
    sys.exit(0)
except FileNotFoundError:
    print(f"loom-canary-heal: {agent} not executable", file=sys.stderr)
    sys.exit(2)

text = (proc.stdout or "") + "\n" + (proc.stderr or "")
heal = {
    "heal_status": "blocked",
    "diagnosis": "agent produced no HEAL_RESULT line",
    "repo": "",
    "pr_url": "",
    "merge_sha": "",
    "attempt": attempt,
}
for line in text.splitlines():
    line = line.strip()
    if not line.startswith("HEAL_RESULT"):
        continue
    raw_json = line[len("HEAL_RESULT"):].strip()
    try:
        parsed = json.loads(raw_json)
    except json.JSONDecodeError:
        continue
    if isinstance(parsed, dict):
        heal.update({k: parsed.get(k, heal.get(k)) for k in heal})
        break

status = str(heal.get("heal_status") or "blocked")
if status not in ("fixed", "blocked", "noop"):
    status = "blocked"
    heal["heal_status"] = status

if status == "fixed":
    print(f'LOOM_EFFECT_INTENT:{{"kind":"pr_merge","target":"{heal.get("pr_url") or key}"}}')
    print(f'LOOM_EFFECT_DONE:{{"kind":"pr_merge","target":"{heal.get("pr_url") or key}"}}')

emit(
    heal,
    f"canary-heal exec={exec_id or '-'} status={status} sha={(heal.get('merge_sha') or '')[:12]}",
)
sys.exit(0 if proc.returncode == 0 or status in ("fixed", "noop", "blocked") else 1)
PY
