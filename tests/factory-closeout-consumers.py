#!/usr/bin/env python3
"""Black-box closeout consumers. No live board, forge, or host state."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PR = "https://github.com/EdgeVector/example/pull/123"
FINITE = ["factory-scoped-dispatch-20261008", "factory-guarded-closeout-20261008",
          "factory-canonical-active-counts-20261008", "factory-repair-controller-20261009"]
BASE = "Repo: EdgeVector/example\nBase: main\nKind: pr\n## GOAL\nCheck the result.\n## END STATE\nThe result satisfies the test.\n"
CASES = ["fail", "pending", "negated", "outcome-unmet", "outcome-latest-positive",
         "reopen-marker", "legacy-marker", "proof-error", "foreign-card", "missing-card-slug", "done-when-pending", "absent-strict",
         "absent-ordinary", "finite", "contract-error", "contract-malformed", "contract-bad-sha", "contract-sha-array", "contract-sha-newline", "contract-key-newline",
         "missing-helper", "helper-nonexec", "helper-directory", "stale-helper-nonexec", "stale-helper-directory", "stale-missing-helper", "missing-batch-helper", "deferred-fail", "deferred-pending", "deferred-reopen",
         "deferred-done-when"]

def executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)

def fixture(case):
    tmp = Path(tempfile.mkdtemp(prefix="factory-closeout-consumer-"))
    stack = tmp / "artifact"
    (stack / "bin").mkdir(parents=True)
    (stack / "lib").mkdir()
    for name in ["last-stack-card-closeout", "last-stack-board-closeout-sweep", "last-stack-card-closeout-merge-probe"]:
        shutil.copy2(ROOT / "bin" / name, stack / "bin" / name)
    for name in ["closeout_evidence.py", "sanitize_structured_fields.py"]:
        shutil.copy2(ROOT / "lib" / name, stack / "lib" / name)
    contract = {"version": 1, "result": "ok", "contract_sha256": "c" * 64, "protected_card_keys": list(FINITE)}
    if case == "contract-malformed":
        contract["protected_card_keys"] = []
    if case == "contract-bad-sha": contract["contract_sha256"] = "incorrect"
    if case == "contract-sha-array": contract["contract_sha256"] = ["c" * 64]
    if case == "contract-sha-newline": contract["contract_sha256"] = "c" * 64 + "\n"
    if case == "contract-key-newline": contract["protected_card_keys"][0] += "\n"
    contract_program = "#!" + sys.executable + "\nimport json,sys\nprint(" + repr(json.dumps(contract)) + ")\nsys.exit(" + ("2" if case == "contract-error" else "0") + ")\n"
    # The local artifact validator is an external dependency here. Its own
    # tests bind files/hashes; these fixtures isolate the consumer refusal.
    executable(stack / "bin/last-stack-factory-repair-contract", contract_program)
    executable(stack / "bin/last-stack-kanban-show-batch", "#!" + sys.executable + "\nimport json,os\nfrom pathlib import Path\np=Path(os.environ['FIXTURE_HOME'])\nprint(json.dumps([json.loads((p/'card.json').read_text())]))\n")
    body = BASE
    if case == "fail": body += "PROOF: PASS old check\nPROOF: FAIL current check\n"
    if case == "pending": body += "PROOF: PASS old check\nPROOF: PENDING current check\n"
    if case == "negated": body += "PROOF: PASS old check\nPROOF: not verified on the current program\n"
    if case == "proof-error": body += "PROOF: ERROR after passed unit tests\n"
    if case == "outcome-unmet": body += "PROOF: PASS old check\n## OUTCOME\nThe END STATE is unmet.\n"
    if case == "outcome-latest-positive": body += "## OUTCOME\nThe END STATE is unmet.\n## OUTCOME\nThe END STATE is verified.\n"
    if case == "reopen-marker": body += "PROOF: PASS old check\nPROOF[reopened-end-state-unmet]: current helper fails\n"
    if case == "legacy-marker":
        proofs = ["PASS old check", "VERIFIED another old check"]
        material = "closeout-v1\npr=" + PR + "\nproof=" + "\n".join(proofs)
        body += "\n".join("PROOF: " + p for p in proofs) + "\nCLOSEOUT-DECISION signal=" + hashlib.sha256(material.encode()).hexdigest() + " state=closed\n"
    if case == "done-when-pending":
        body += "PROOF: PASS old check\nDONE-WHEN: false\n"
        executable(stack / "bin/last-stack-kanban-done-when-eval", "#!/bin/sh\necho 'NOT met'\nexit 1\n")
    if case == "finite" or case.startswith("contract-") or case in {"missing-helper", "helper-nonexec", "helper-directory"}: body += "PROOF: PASS current check\n"
    slug = FINITE[0] if case == "finite" else "fixture-card"
    card = {"slug": slug, "title": "Closeout fixture", "column": "doing", "position": "100", "board": "default", "body": body,
            "pr_url": PR, "branch": "kanban/fixture", "repo": "EdgeVector/example", "base": "main", "assignee": "worker",
            "block_status": "none", "block_reason": "", "tags": [], "updated_at": "2020-01-01T00:00:00Z"}
    if case == "foreign-card": card["slug"] = "another-card"
    if case == "missing-card-slug": del card["slug"]
    if case.startswith("deferred-"):
        card["tags"] = ["awaiting-deploy"]
    # A finite exclusion must also beat URL heal and age reclaim. The PR is
    # deliberately body-only and very old in that case.
    if case in {"finite", "missing-helper", "helper-nonexec", "helper-directory"}:
        card["pr_url"] = ""
        card["body"] += "PR: " + PR + "\n"
    if case.startswith("stale-"):
        card["pr_url"] = ""
        card["body"] += "STALE-PR REAP: the prior PR is closed.\n"
        (tmp / "home/code/edgevector/example/.git").mkdir(parents=True)
        executable(tmp / "path/git", "#!/bin/sh\ncase \"$*\" in *rev-parse*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;; *merge-base*) exit 0;; *) exit 1;; esac\n")
    (tmp / "card.json").write_text(json.dumps(card))
    board_source = '''import json,os,sys
from pathlib import Path
p=Path(os.environ["FIXTURE_HOME"])
c=json.loads((p/"card.json").read_text()); a=sys.argv[1:]
if a[0]=="list": print(json.dumps({"cards":[c]})); sys.exit(0)
if a[0]=="show": print(json.dumps(c)); sys.exit(0)
with (p/"writes.jsonl").open("a") as f: f.write(json.dumps(a)+"\\n")
if a[0]=="move": c["column"]=a[2]
elif a[0]=="mark": c["body"]+="\\n"+a[2]+"\\n"
elif a[0] in {"add","set"}:
 for flag,key in [("--pr-url","pr_url"),("--branch","branch"),("--assignee","assignee")]:
  if flag in a: c[key]=a[a.index(flag)+1]
(p/"card.json").write_text(json.dumps(c)); print("{}")
'''
    executable(tmp / "board", "#!" + sys.executable + "\n" + board_source)
    executable(tmp / "path/gh", "#!" + sys.executable + "\nimport json\nprint(json.dumps(" + repr({"state": "MERGED", "merged": True, "mergedAt": "2026-10-09T00:00:00Z", "merge_commit_sha": "a" * 40}) + "))\n")
    executable(tmp / "path/host-track", "#!" + sys.executable + "\nimport json,os,sys\nfrom pathlib import Path\np=Path(os.environ['FIXTURE_HOME'])\nwith (p/'writes.jsonl').open('a') as f: f.write(json.dumps(['unplanned-host-track']+sys.argv[1:])+'\\n')\nsys.exit(2)\n")
    env = dict(os.environ, HOME=str(tmp / "home"), PATH=str(tmp / "path") + os.pathsep + os.environ["PATH"], FIXTURE_HOME=str(tmp),
               BOARD_CLOSEOUT_STATE_DIR=str(tmp / "state"), LAST_STACK_HEARTBEATS_FILE=str(tmp / "heartbeats"),
               LAST_STACK_CARD_CLOSEOUT_COMMAND_TIMEOUT_SEC="5", BOARD_CLOSEOUT_TIMEOUT_SEC="30")
    return tmp, stack, env

def writes(tmp):
    p = tmp / "writes.jsonl"
    return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

def run_direct(case):
    tmp, stack, env = fixture(case)
    if case == "absent-strict": env["LAST_STACK_CARD_CLOSEOUT_END_STATE_GATE"] = "1"
    p = subprocess.run([str(stack / "bin/last-stack-card-closeout"), "fixture-card" if case != "finite" else FINITE[0], "--board-cli", str(tmp / "board")], env=env, capture_output=True, text=True, timeout=20)
    events = writes(tmp)
    card = json.loads((tmp / "card.json").read_text())
    positive = case in {"absent-ordinary", "outcome-latest-positive"}
    if positive:
        assert card["column"] == "done" and p.returncode == 0, (case, card, p.stdout, p.stderr)
        assert any(a[:3] == ["move", card["slug"], "done"] for a in events), (case, events)
    else:
        assert card["column"] == "doing", (case, events, card, p.stderr)
        assert not any(a[0] in {"add", "set", "move"} for a in events), (case, events, p.stderr)
        if case != "done-when-pending": assert not events, (case, events, p.stderr)
        assert p.returncode != 0, (case, p.stdout, p.stderr)
        reasons = {"fail": "proof-negative", "pending": "proof-pending", "negated": "proof-negative", "outcome-unmet": "proof-negative",
                   "reopen-marker": "proof-negative", "legacy-marker": "reopened-same-signal", "proof-error": "proof-error",
                   "foreign-card": "factory-contract-refused", "missing-card-slug": "factory-contract-refused", "done-when-pending": "done-when-pending",
                   "absent-strict": "end-state-unverified", "finite": "factory-finite-excluded", "contract-error": "factory-contract-refused",
                   "contract-malformed": "factory-contract-refused", "contract-bad-sha": "factory-contract-refused",
                   "contract-sha-array": "factory-contract-refused", "contract-sha-newline": "factory-contract-refused", "contract-key-newline": "factory-contract-refused"}
        assert reasons[case] in p.stderr, (case, p.stderr)
    print("PASS direct " + case)

def run_sweep(case, engine):
    tmp, stack, env = fixture(case)
    env["BOARD_CLOSEOUT_ENGINE"] = engine
    if case in {"missing-helper", "stale-missing-helper"}:
        (stack / "bin/last-stack-card-closeout").unlink()
    elif case in {"helper-nonexec", "stale-helper-nonexec"}:
        (stack / "bin/last-stack-card-closeout").chmod(0o644)
    elif case in {"helper-directory", "stale-helper-directory"}:
        (stack / "bin/last-stack-card-closeout").unlink()
        (stack / "bin/last-stack-card-closeout").mkdir()
    elif case == "missing-batch-helper":
        (stack / "bin/last-stack-kanban-show-batch").unlink()
    elif case.startswith("deferred-"):
        reason = {"deferred-fail": "proof-negative", "deferred-pending": "proof-pending", "deferred-reopen": "reopened-same-signal", "deferred-done-when": "done-when-pending"}[case]
        executable(stack / "bin/last-stack-card-closeout", "#!/bin/sh\necho 'last-stack-card-closeout: FAILED " + reason + "' >&2\nexit 1\n")
        (tmp / "state").mkdir()
        (tmp / "state/close-failures.json").write_text(json.dumps({"fixture-card": {"count": 8, "last_reason": "stale", "escalated": True}}))
    passes = 4 if case.startswith("deferred-") else 1
    for _ in range(passes):
        command = [str(stack / "bin/last-stack-board-closeout-sweep"), "--board-cli", str(tmp / "board"), "--grace-min", "1", "--max-park-hours", "1", "--escalate-after", "1"]
        if not case.startswith("stale-"): command.append("--skip-zombie")
        p = subprocess.run(command, env=env, capture_output=True, text=True, timeout=40)
        events = writes(tmp)
        card = json.loads((tmp / "card.json").read_text())
        assert not events and card["column"] == "doing" and card["assignee"] == "worker", (case, engine, events, card, p.stdout, p.stderr)
        result = json.loads(p.stdout.splitlines()[0])
        assert not result.get("close_failed"), (case, engine, result)
        if case == "finite": assert any("factory-finite-excluded" in x for x in result["flagged"]), result
        elif case in {"missing-helper", "helper-nonexec", "helper-directory"} or case.startswith("stale-"): assert any("closeout-helper-missing" in x for x in result["flagged"]), result
        elif case == "missing-batch-helper": assert any("card-read-failed" in x for x in result["flagged"]), result
        elif case.startswith("contract-"): assert result["status"] == "error" and "factory-contract-refused" in result["flagged"], result
        else:
            state = json.loads((tmp / "state/close-failures.json").read_text())
            assert "fixture-card" not in state, (case, engine, state)
            assert not any("close-failed" in x or "park-expired" in x for x in result["flagged"]), result
    print("PASS " + engine + " " + case)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--engine", choices=["direct", "node", "python3", "all"], default="all")
    args = parser.parse_args()
    cases = [args.case] if args.case else CASES
    for case in cases:
        if args.engine in {"direct", "all"} and case not in {"missing-helper", "helper-nonexec", "helper-directory", "missing-batch-helper"} and not case.startswith(("deferred-", "stale-")):
            try: run_direct(case)
            except Exception as exc: raise AssertionError("FAIL direct " + case) from exc
        if args.engine != "direct" and (case in {"finite", "missing-helper", "helper-nonexec", "helper-directory", "missing-batch-helper"} or case.startswith(("contract-", "deferred-", "stale-"))):
            engines = ["node", "python3"] if args.engine == "all" else [args.engine]
            for engine in engines:
                if engine == "node" and not shutil.which("node"): continue
                try: run_sweep(case, engine)
                except Exception as exc: raise AssertionError("FAIL " + engine + " " + case) from exc

if __name__ == "__main__": main()
