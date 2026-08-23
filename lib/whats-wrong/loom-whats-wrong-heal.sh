#!/usr/bin/env bash
# HEAL node: one EV OPS "What's wrong" exception.
# Default is a contract stand-in (CI / cargo test). LOOM_WHATS_WRONG_LIVE=1
# (or LOOM_LIVE=1) runs grok/claude against the host with hard Last Stack
# guardrails. Never restarts primary lastdbd.
set -euo pipefail

python3 <<'PY'
import datetime
import json, os, shutil, subprocess, sys, tempfile, textwrap, time, urllib.request

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
    # Join captures the last non-prefix stdout line as the branch result.
    # PASS last would collapse every branch to {"stdout":"PASS"}.
    print(json.dumps(payload, separators=(",", ":")))

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

home = os.path.expanduser("~")
ls_bin = os.path.join(home, ".last-stack", "bin")


def run(argv, timeout=120):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return None
    except subprocess.TimeoutExpired:
        return "timeout"


def which_ls(name):
    p = os.path.join(ls_bin, name)
    if os.path.isfile(p) and os.access(p, os.X_OK):
        return p
    return shutil.which(name)


def mechanical_heal(eid):
    """Deterministic heals for known dashboard rows. Never restarts lastdbd."""
    if eid == "ship.why-stopped-loom":
        exe = which_ls("last-stack-why-stopped-loom")
        if not exe:
            return "blocked", "why-stopped-loom missing", ""
        r = run([exe, "--json", "--quiet"], 180)
        if r == "timeout":
            return "blocked", "why-stopped-loom timed out", ""
        if r is None or r.returncode not in (0, 3):
            return "blocked", f"why-stopped-loom rc={getattr(r,'returncode',None)}", ""
        stamp = os.path.join(home, ".last-stack", "state", "why-stopped-loom.json")
        try:
            d = json.load(open(stamp))
            age_h = 99.0
            ts = d.get("ts") or ""
            t = datetime.datetime.strptime(ts.replace("Z", ""), "%Y-%m-%dT%H:%M:%S").replace(
                tzinfo=datetime.timezone.utc
            )
            age_h = (datetime.datetime.now(datetime.timezone.utc) - t).total_seconds() / 3600.0
            if d.get("status") == "succeeded" and age_h < 4.5:
                return "healed", f"stamp ageH={age_h:.2f} classes={d.get('classes')}", ""
        except Exception as e:
            return "blocked", f"stamp unreadable: {e}", ""
        return "noop", "stamp still stale/failed", ""

    if eid == "proc.routines-web":
        try:
            urllib.request.urlopen("http://127.0.0.1:4778/", timeout=5).read(64)
            return "healed", "http://127.0.0.1:4778/ already HTTP 200", ""
        except Exception:
            pass
        uid = os.getuid()
        job = f"gui/{uid}/com.edgevector.routines-web"
        run(["launchctl", "kickstart", "-k", job], 20)
        time.sleep(2)
        try:
            urllib.request.urlopen("http://127.0.0.1:4778/", timeout=8).read(64)
            return "healed", "kickstarted com.edgevector.routines-web; HTTP 200", ""
        except Exception as e2:
            run(["launchctl", "kickstart", job], 20)
            time.sleep(2)
            try:
                urllib.request.urlopen("http://127.0.0.1:4778/", timeout=8).read(64)
                return "healed", "second kickstart; HTTP 200", ""
            except Exception as e3:
                return "blocked", f"4778 still down: {e3}", "papercut-whats-wrong-routines-web-hung"

    if eid == "app.last-stack":
        exe = shutil.which("host-track") or os.path.join(home, ".local/bin/host-track")
        if not os.path.isfile(exe):
            return "blocked", "host-track missing", ""
        run([exe, "refresh", "last-stack"], 180)
        r = run([exe, "status", "last-stack", "--json"], 30)
        if r and r != "timeout" and r.stdout:
            try:
                d = json.loads(r.stdout)
                if d.get("freshness") == "fresh" and d.get("stale") is False:
                    return "healed", f"host_head={d.get('host_head')}", ""
                return (
                    "papercut",
                    f"still {d.get('freshness')} host={str(d.get('host_head') or '')[:12]} gate={str(d.get('gate_head') or '')[:12]}",
                    "papercut-lastgit-artifact-promote-requires-ci-on-merge-oid",
                )
            except json.JSONDecodeError:
                pass
        return "noop", "host-track refresh did not report fresh", ""

    if eid in ("machine.disk-lastdb", "machine.disk"):
        rec = which_ls("last-stack-worktree-reclaim")
        if rec:
            run([rec, "--sweep-stale", "--max-age-hours", "48"], 180)
        try:
            out = subprocess.check_output(["df", "-k", "/System/Volumes/Data"], text=True, timeout=10)
            line = out.strip().splitlines()[-1].split()
            avail_g = int(line[3]) / 1024 / 1024
            cap = int(line[4].rstrip("%"))
        except Exception as e:
            return "blocked", f"df failed: {e}", ""
        if avail_g >= 80 and cap < 85:
            return "healed", f"availGiB={avail_g:.1f} capPct={cap}", ""
        return (
            "papercut",
            f"availGiB={avail_g:.1f} capPct={cap}; backup prune blocked (consecutive_failures>0); APFS 85% needs ~139Gi free on 926Gi",
            "papercut-whats-wrong-disk-ok-needs-15pct-on-926g",
        )

    if eid == "machine.load":
        load1 = os.getloadavg()[0]
        ncpu = os.cpu_count() or 1
        if load1 <= ncpu:
            return "healed", f"load1={load1:.2f} ncpu={ncpu}", ""
        return "noop", f"load1={load1:.2f} still > ncpu={ncpu} (transient; do not kill lastdbd)", ""

    return None


mech = mechanical_heal(exc_id)
if mech is not None:
    status, evidence, pc = mech
    emit(
        {
            "id": exc_id,
            "label": label,
            "heal_status": status,
            "papercut": pc,
            "evidence": evidence,
        },
        f"whats-wrong-heal mechanical id={exc_id} status={status}",
    )
    if os.environ.get("WHATS_WRONG_MECHANICAL_ONLY") == "1" or status == "healed":
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
