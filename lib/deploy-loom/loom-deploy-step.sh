#!/usr/bin/env bash
# deploy-main graph steps: STAGE → DEPLOY (checked effect) → VERIFY.
#
# Input (LOOM_INPUT JSON): repo, oid, source_url, deploy_script, context,
# state_root, optional verify_command and env. Every path is derived from
# state_root/<repo>/<oid>, so two repos or two OIDs never share a directory,
# and a resumed execution finds what the first attempt left.
#
# The deploy script is the repo's own (.lastgit/deploy-prod.sh or
# deploy-pipeline.sh), run from the staged checkout with the same variables
# the old launchd watcher gave it (LASTGIT_CI_OID / _CONTEXT / _REPO). This
# runner adds nothing to what gets deployed; it adds durability around it.
set -euo pipefail
step="${1:?step}"
exec python3 - "$step" <<'PY'
import json, os, shutil, subprocess, sys, time
from pathlib import Path

step = sys.argv[1]
try:
    ctx = json.loads(os.environ.get("LOOM_INPUT") or "{}")
except json.JSONDecodeError:
    ctx = {}
item = ctx.get("item")
if isinstance(item, dict):
    ctx = {**item, **{k: v for k, v in ctx.items() if k != "item"}}

repo = str(ctx.get("repo") or "")
oid = str(ctx.get("oid") or "")
source_url = str(ctx.get("source_url") or "")
deploy_script = str(ctx.get("deploy_script") or "")
context = str(ctx.get("context") or "deploy-prod")
verify_command = str(ctx.get("verify_command") or "")
state_root = Path(str(ctx.get("state_root") or ""))
extra_env = ctx.get("env") if isinstance(ctx.get("env"), dict) else {}
for name, value in (("repo", repo), ("oid", oid), ("source_url", source_url),
                    ("deploy_script", deploy_script), ("state_root", str(state_root))):
    if not value:
        print(f"deploy-main: {name} is required", file=sys.stderr)
        raise SystemExit(2)

work = state_root / repo / oid
stage = work / "src"
receipt = work / "deploy-receipt.json"
log = work / "deploy.log"


def emit(patch, line="PASS"):
    print("LOOM_CONTEXT_PATCH:" + json.dumps(patch, separators=(",", ":")))
    print(line)
    print("PASS")


def run(cmd, **kw):
    kw.setdefault("check", False)
    return subprocess.run(cmd, **kw)


def git_env():
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    token = os.environ.get("FORGE_TOKEN", "").strip()
    if not token and source_url.startswith(("http://localhost:3300/", "http://127.0.0.1:3300/")):
        lib = Path(os.environ.get("LAST_STACK_ROOT", str(Path.home() / ".last-stack"))) / "lib" / "forge-token.sh"
        if lib.is_file():
            proc = run(["bash", "-c", f'. "{lib}" && last_stack_forge_token'], capture_output=True, text=True)
            token = proc.stdout.strip() if proc.returncode == 0 else ""
    if token:
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "http.http://localhost:3300/.extraHeader"
        env["GIT_CONFIG_VALUE_0"] = f"Authorization: token {token}"
    return env


if step == "STAGE":
    # A staged checkout at exactly this OID. Re-entrant: an existing correct
    # stage is kept, anything else is replaced.
    head = ""
    if (stage / ".git").is_dir():
        p = run(["git", "-C", str(stage), "rev-parse", "HEAD"], capture_output=True, text=True)
        head = p.stdout.strip() if p.returncode == 0 else ""
    if head != oid:
        shutil.rmtree(stage, ignore_errors=True)
        work.mkdir(parents=True, exist_ok=True)
        clone = run(["git", "clone", "--quiet", "--no-checkout", source_url, str(stage)],
                    capture_output=True, text=True, env=git_env())
        if clone.returncode != 0:
            print(f"deploy-main STAGE: clone failed: {clone.stderr.strip()}", file=sys.stderr)
            raise SystemExit(1)
        co = run(["git", "-C", str(stage), "checkout", "--quiet", "--detach", oid],
                 capture_output=True, text=True, env=git_env())
        if co.returncode != 0:
            print(f"deploy-main STAGE: {oid} is not in {source_url}: {co.stderr.strip()}", file=sys.stderr)
            raise SystemExit(1)
    script = stage / deploy_script
    if not script.is_file():
        print(f"deploy-main STAGE: deploy script missing at {oid}: {deploy_script}", file=sys.stderr)
        raise SystemExit(1)
    emit({"stage_dir": str(stage), "staged_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})

elif step == "CHECK":
    # Resume check for the DEPLOY effect: 0 = this OID's deploy already landed.
    if receipt.is_file():
        try:
            data = json.loads(receipt.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            data = {}
        if data.get("oid") == oid and data.get("rc") == 0:
            raise SystemExit(0)
    raise SystemExit(1)

elif step == "DEPLOY":
    if receipt.is_file():
        try:
            data = json.loads(receipt.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            data = {}
        if data.get("oid") == oid and data.get("rc") == 0:
            emit({"deployed": True, "deploy_rc": 0, "receipt": str(receipt), "deploy_reused": True})
            raise SystemExit(0)
    print(f'LOOM_EFFECT_INTENT:{json.dumps({"kind": "deploy", "target": repo}, separators=(",", ":"))}')
    work.mkdir(parents=True, exist_ok=True)
    env = {**os.environ, **{str(k): str(v) for k, v in extra_env.items()},
           "LASTGIT_CI_OID": oid, "LASTGIT_CI_CONTEXT": context, "LASTGIT_CI_REPO": repo,
           "LAST_STACK_DEPLOY_LOOM": "1"}
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with log.open("a", encoding="utf-8") as fh:
        fh.write(f"== deploy-main DEPLOY repo={repo} oid={oid} script={deploy_script} at {started}\n")
        fh.flush()
        proc = subprocess.run(["bash", deploy_script], cwd=str(stage), env=env, stdout=fh, stderr=subprocess.STDOUT, check=False)
    finished = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    receipt.write_text(json.dumps({
        "repo": repo, "oid": oid, "context": context, "deploy_script": deploy_script,
        "rc": proc.returncode, "started_at": started, "finished_at": finished, "log": str(log),
    }, indent=2) + "\n", encoding="utf-8")
    if proc.returncode != 0:
        tail = ""
        try:
            tail = "".join(log.read_text(encoding="utf-8").splitlines(keepends=True)[-15:])
        except OSError:
            pass
        print(f"deploy-main DEPLOY: {deploy_script} exited {proc.returncode}\n{tail}", file=sys.stderr)
        raise SystemExit(1)
    emit({"deployed": True, "deploy_rc": 0, "receipt": str(receipt)})

elif step == "VERIFY":
    if not verify_command:
        emit({"verified": "skipped"})
        raise SystemExit(0)
    env = {**os.environ, "DEPLOY_OID": oid, "DEPLOY_REPO": repo}
    deadline = time.time() + int(os.environ.get("LOOM_DEPLOY_VERIFY_SECS", "600"))
    last = ""
    while True:
        proc = run(["bash", "-c", verify_command], capture_output=True, text=True, env=env)
        if proc.returncode == 0:
            emit({"verified": "ok"})
            raise SystemExit(0)
        last = (proc.stderr or proc.stdout).strip()[-300:]
        if time.time() >= deadline:
            break
        time.sleep(15)
    print(f"deploy-main VERIFY: command did not pass before the deadline: {last}", file=sys.stderr)
    raise SystemExit(1)

else:
    print(f"deploy-main: unknown step {step}", file=sys.stderr)
    raise SystemExit(2)
PY
