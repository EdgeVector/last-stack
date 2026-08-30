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

def blocked_harnesses():
    """Harnesses an active Situation forbids dispatching to.

    routinesd honours `harness-outage-*` through its fallback chain, but this
    node re-execs a harness itself, so it must read the same source. A harness
    in usage-limit outage answers 402 and prints no HEAL_RESULT line, which the
    fallback below records as "agent produced no HEAL_RESULT line" — a true
    statement that names neither the outage nor the cause
    (papercut-canary-heal-adapter-dispatches-grok-during-active-harness-outage).

    Fails OPEN: an unreadable Situations list must never stop a heal, because
    the lane is already red when this node runs.
    """
    exe = shutil.which("situations")
    if not exe:
        return set(), ""
    try:
        p = subprocess.run(
            [exe, "list", "--json"], capture_output=True, text=True, timeout=30
        )
        rows = json.loads(p.stdout or "[]")
    except Exception:
        return set(), ""
    if not isinstance(rows, list):
        return set(), ""
    blocked, slugs = set(), []
    for row in rows:
        if not isinstance(row, dict) or row.get("status") != "active":
            continue
        for action in row.get("blocked_actions") or []:
            a = str(action)
            if a.startswith("dispatch-") and a.endswith("-agents"):
                blocked.add(a[len("dispatch-") : -len("-agents")])
                slugs.append(str(row.get("slug") or ""))
    return blocked, ",".join(sorted(s for s in slugs if s))


CANDIDATES = ("grok", "claude")
fenced, outage_slugs = blocked_harnesses()
on_path = [c for c in CANDIDATES if shutil.which(c)]
agent = next((c for c in on_path if c not in fenced), None)
if not agent:
    if on_path:
        # Every harness we could run is fenced by an active outage. Say so, so
        # the execution record explains itself instead of blaming the agent.
        payload = {
            "heal_status": "blocked",
            "diagnosis": (
                "every heal harness is fenced by an active Situation: "
                f"{'/'.join(on_path)} blocked by {outage_slugs or 'harness outage'}"
            ),
            "repo": "",
            "pr_url": "",
            "merge_sha": "",
            "attempt": attempt,
        }
        emit(payload, f"canary-heal fenced exec={exec_id or '-'} harnesses={'/'.join(on_path)}")
        sys.exit(0)
    print("loom-canary-heal: grok/claude not on PATH", file=sys.stderr)
    sys.exit(2)
if fenced:
    print(
        f"loom-canary-heal: skipping fenced harness(es) {'/'.join(sorted(fenced))}; using {agent}",
        file=sys.stderr,
    )


def recover_child_evidence():
    """Fill exec_id and probe evidence from the failed safe-upgrade child.

    JOIN_A routes a child failure straight to HEAL, so the parent context has
    no exec_id and no probe tail — heal lx-20260830T195506 dispatched an agent
    with "(no probe tail)". The child is addressable by its idempotency key
    "<parent exec id>#upgrade#<n>", and the step wrapper persists driver output
    as <candidate dir>/{probe,cutover}-fail-*.log. Fail open: a heal must
    still run blind when recovery fails.
    """
    global exec_id, probe
    parent = os.environ.get("LOOM_EXEC_ID") or ""
    scripts_dir = os.environ.get("LOOM_SCRIPTS") or os.path.expanduser(
        "~/.last-stack/lib/canary-loom"
    )
    helper = os.path.join(
        os.path.dirname(os.path.dirname(scripts_dir)), "bin", "last-stack-loom-exec-latest"
    )
    if not os.path.isfile(helper):
        helper = os.path.expanduser("~/.last-stack/bin/last-stack-loom-exec-latest")
    child = None
    if parent and not exec_id and os.path.isfile(helper):
        try:
            p = subprocess.run(
                [helper, "--definition", "lastdb-safe-upgrade", "--window-hours", "24"],
                capture_output=True, text=True, timeout=60,
            )
            rows = json.loads(p.stdout or "[]")
            for row in rows if isinstance(rows, list) else []:
                if str(row.get("idempotency_key") or "").startswith(parent + "#"):
                    child = row
                    break
        except Exception as err:
            print(f"loom-canary-heal: child lookup failed: {err}", file=sys.stderr)
    if child:
        exec_id = str(child.get("id") or child.get("exec_id") or "")
    if not probe and exec_id:
        try:
            p = subprocess.run(
                ["loom", "show", exec_id], capture_output=True, text=True, timeout=60
            )
            keep = []
            for line in (p.stdout or "").splitlines():
                if line.startswith(("status:", "state:", "error:", "node ")) or line.startswith(
                    ("context.last_error:", "context.probe_tail:", "context.probe_rc:", "context.verdict:")
                ):
                    keep.append(line)
            if keep:
                probe = "\n".join(keep)
        except Exception as err:
            print(f"loom-canary-heal: loom show failed: {err}", file=sys.stderr)
    candidate = str(ctx.get("candidate") or "")
    if candidate:
        try:
            cand_dir = os.path.dirname(candidate)
            logs = sorted(
                (
                    os.path.join(cand_dir, name)
                    for name in os.listdir(cand_dir)
                    if name.startswith(("probe-fail-", "cutover-fail-")) and name.endswith(".log")
                ),
                key=os.path.getmtime,
            )
            if logs:
                with open(logs[-1], encoding="utf-8") as handle:
                    tail = handle.read()[-3000:]
                probe = (probe + "\n\n" if probe else "") + f"--- {logs[-1]} ---\n{tail}"
        except OSError as err:
            print(f"loom-canary-heal: evidence file read failed: {err}", file=sys.stderr)


if not exec_id or not probe:
    recover_child_evidence()

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
found = False
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
        found = True
        break

if not found:
    # "agent produced no HEAL_RESULT line" is true but names no cause, so every
    # reader re-derives it from the harness. Carry the agent's own last words.
    tail = [ln.strip() for ln in text.splitlines() if ln.strip()][-3:]
    if tail:
        joined = " | ".join(tail)
        if len(joined) > 400:
            joined = joined[:397] + "..."
        heal["diagnosis"] = (
            f"agent produced no HEAL_RESULT line (agent={agent}, rc={proc.returncode}); "
            f"last output: {joined}"
        )

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
