#!/usr/bin/env python3
"""Offline process tests: a rejected check must never execute the mutation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHA = "a" * 40
BRANCH = "kanban/test-pr"

MOCK = '''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["GUARD_FIXTURE"])
data = json.loads((root / "fixture.json").read_text())
name = pathlib.Path(sys.argv[0]).name
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps([name, *sys.argv[1:]]) + "\\n")
if name == "mutate":
    (root / "mutated").write_text("yes")
    sys.exit(0)
if name == "kanban":
    calls = (root / "calls.jsonl").read_text().count('"kanban"')
    print(json.dumps(data.get("card_final", data["card"]) if calls > 1 else data["card"]))
elif "/pulls/" in sys.argv[1]:
    calls = (root / "calls.jsonl").read_text().count('"repos/EdgeVector/fold/pulls/7"')
    print(json.dumps(data.get("pr_final", data["pr"]) if calls > 1 else data["pr"]))
elif "/status" in sys.argv[1]:
    print(json.dumps(data["status"]))
elif "/actions/tasks?" in sys.argv[1]:
    if data.get("task_error"):
        print("HTTP 400 private-response-must-stay-secret", file=sys.stderr)
        sys.exit(1)
    state = sys.argv[1].split("status=")[1].split("&")[0]
    rows = [r for r in data["tasks"] if r.get("status") == state]
    print(json.dumps(data.get("task_response", {"workflow_runs": rows, "total_count": len(rows)})))
else:
    sys.exit(99)
'''


class GuardTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pipeline-pr-guard-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        shutil.copy2(ROOT / "bin/last-stack-pipeline-pr-guard", self.bin)
        for name in ("last-stack-forge-api", "kanban", "mutate"):
            path = self.bin / name
            path.write_text(MOCK)
            path.chmod(0o755)
        self.data = {
            "pr": {"number": 7, "state": "open", "merged": False, "draft": False,
                   "head": {"sha": SHA, "ref": BRANCH}},
            "card": {"slug": "test-pr", "repo": "EdgeVector/fold", "branch": BRANCH,
                     "kind": "pr", "pr_url": "http://forge.test/EdgeVector/fold/pulls/7",
                     "assignee": "", "column": "review", "blocked": False},
            "status": {"state": "failure", "total_count": 1,
                       "statuses": [{"status": "failure", "context": "ci-required"}]},
            "tasks": [{"id": 1, "head_sha": SHA, "status": "failure"}],
        }

    def run_guard(self, reason=None, probe=False):
        (self.home / "fixture.json").write_text(json.dumps(self.data))
        env = dict(os.environ, GUARD_FIXTURE=str(self.home), PATH=f"{self.bin}:{os.environ['PATH']}")
        command = [str(self.bin / "last-stack-pipeline-pr-guard"), "--repo", "EdgeVector/fold",
                   "--pr", "7", "--expected-head", SHA]
        if not probe:
            command += ["--", str(self.bin / "mutate")]
        result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=10)
        answer = json.loads(result.stdout)
        self.assertNotIn("private-response", result.stdout + result.stderr)
        self.assertEqual(result.returncode, 3 if reason else 0, result.stderr)
        self.assertEqual(answer["verdict"], "deny" if reason else "allow")
        if reason:
            self.assertEqual(answer["reason"], reason)
        self.assertEqual((self.home / "mutated").exists(), not reason and not probe)
        calls = [json.loads(line) for line in (self.home / "calls.jsonl").read_text().splitlines()]
        self.assertEqual(any(row[0] == "mutate" for row in calls), not reason and not probe)
        return calls

    def test_assigned_pr_never_mutates(self):
        self.data["card"]["assignee"] = "codex:owner"
        self.run_guard("owned-pr")

    def test_same_head_owner_retry_never_mutates_even_with_terminal_status(self):
        self.data["tasks"].append({"id": 2, "head_sha": SHA, "status": "running"})
        self.run_guard("active-head-task")

    def test_queued_same_head_retry_never_mutates(self):
        self.data["tasks"].append({"id": 2, "head_sha": SHA, "status": "waiting"})
        self.run_guard("active-head-task")

    def test_changed_head_never_mutates(self):
        self.data["pr"]["head"]["sha"] = "b" * 40
        self.run_guard("head-changed")

    def test_unreadable_task_data_never_mutates(self):
        self.data["task_error"] = True
        self.run_guard("unreadable-evidence")

    def test_unowned_terminal_failure_executes_once_after_fresh_reads(self):
        calls = self.run_guard()
        self.assertEqual(calls[-1], ["mutate"])
        self.assertEqual(sum(row[0] == "kanban" for row in calls), 2)
        self.assertEqual(sum(row[-1].endswith("/pulls/7") for row in calls), 2)
        self.assertEqual(sum("/actions/tasks?" in row[-1] for row in calls), 4)
        self.assertFalse(any("status=all" in row[-1] for row in calls))

    def test_owner_claim_during_reads_never_mutates(self):
        self.data["card_final"] = dict(self.data["card"], assignee="codex:new-owner")
        self.run_guard("owned-pr")

    def test_head_changes_during_reads_never_mutates(self):
        self.data["pr_final"] = dict(self.data["pr"], head={"sha": "b" * 40, "ref": BRANCH})
        self.run_guard("head-changed")

    def test_malformed_tasks_never_mutate(self):
        self.data["task_response"] = {"workflow_runs": [], "total_count": "0"}
        self.run_guard("unreadable-tasks")

    def test_truncated_tasks_never_mutate(self):
        self.data["task_response"] = {"workflow_runs": [], "total_count": 1}
        self.run_guard("incomplete-tasks")

    def test_unbound_card_never_mutates(self):
        self.data["card"]["pr_url"] = "http://forge.test/EdgeVector/fold/pulls/8"
        self.run_guard("unbound-card")

    def test_pending_status_never_mutates(self):
        self.data["status"]["state"] = "pending"
        self.run_guard("active-or-unknown-status")

    def test_foreign_active_task_does_not_block(self):
        self.data["tasks"].append({"id": 2, "head_sha": "b" * 40, "status": "running"})
        self.run_guard()

    def test_probe_never_mutates(self):
        self.run_guard(probe=True)

    def test_prompt_requires_guard_and_forbids_empty_retries(self):
        prompt = " ".join((ROOT / "routines/pipeline-health.md").read_text().split())
        self.assertIn("last-stack-pipeline-pr-guard", prompt)
        self.assertIn("Never create an empty commit", prompt)
        self.assertNotIn("push an empty commit", prompt)
        self.assertNotIn("empty-commit push", prompt)
        self.assertIn("guarded command", prompt)


if __name__ == "__main__":
    unittest.main()
