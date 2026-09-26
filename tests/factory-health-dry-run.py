#!/usr/bin/env python3
"""Prove factory-health dry-run boundaries without the live board or notifier."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

command = Path(__file__).resolve().parents[1] / "bin" / "last-stack-factory-health"
with tempfile.TemporaryDirectory(prefix="factory-health-fixture-") as directory:
    root = Path(directory)
    binaries = root / "bin"
    binaries.mkdir()
    calls = root / "calls.jsonl"
    notifications = root / "notifications"
    state = root / "state"
    stub = binaries / "fixture-tool"
    stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["FIXTURE_CALLS"], "a") as stream:
    stream.write(json.dumps([name, *args]) + "\\n")
if name == "ra":
    Path(os.environ["FIXTURE_NOTIFICATIONS"]).write_text("fixture notification\\n")
    raise SystemExit(0)
if args == ["list", "--json", "--all"]:
    print(json.dumps([{"slug":"fixture-card", "column":"doing", "kind":"pr",
        "title":"Fixture work", "repo":"Fixture/example", "created_at":"2026-01-01T00:00:00Z"}]))
elif args == ["pickup", "status", "--json"]:
    print('{"ready":1}')
elif args == ["milestone", "gap-report", "--json"]:
    print('{"work_queue":[]}')
elif name == "brain" and args[:2] == ["get", "preference-feature-delivery-portfolio-admission"]:
    print(json.dumps({"slug": args[1], "body": "Primary: north-star-fixture\\nSecondary: none\\n"}))
elif args[:3] in (["list", "--column", "todo"], ["list", "--column", "doing"]):
    print('{"cards":[],"total":0,"truncated":false}')
else:
    raise SystemExit(99)
''', encoding="utf-8")
    stub.chmod(0o755)
    for name in ("kanban", "fkanban", "ra", "lastgit", "last-stack-forge-api", "brain"):
        (binaries / name).symlink_to(stub.name)
    config = root / "config.toml"
    config.write_text('''[general]
factory_url = "file:///nonexistent-factory-health-fixture"
[notify]
enabled = true
quiet_hours = []
cooldown_s = 0
[auto_fix]
enabled = false
[doing]
enabled = true
hard_count = 1
''', encoding="utf-8")
    env = {**os.environ, "HOME": str(root), "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
           "FACTORY_HEALTH_STATE_DIR": str(state), "FIXTURE_CALLS": str(calls),
           "FIXTURE_NOTIFICATIONS": str(notifications)}
    argv = [sys.executable, str(command), "--last-stack", str(root), "--config", str(config)]
    dry = subprocess.run([*argv, "--dry-run"], env=env, capture_output=True, text=True, timeout=30)
    assert dry.returncode == 0, dry.stderr
    assert "notify=dry-run" in dry.stdout, dry.stdout
    assert not notifications.exists(), "dry-run reached the notifier"
    assert not (state / "state.json").exists(), "dry-run persisted state"
    supply_dir = root / ".local" / "state" / "last-stack" / "factory-health"
    assert not (supply_dir / "supply-latest.json").exists(), "dry-run persisted supply"
    assert "jammed=north-star-fixture jam_passes=1" in dry.stdout, dry.stdout
    observed = [json.loads(line) for line in calls.read_text().splitlines()]
    kanban_calls = [row for row in observed if row and row[0] == "kanban"]
    assert kanban_calls == [["kanban", "list", "--json", "--all"],
                            ["kanban", "pickup", "status", "--json"],
                            ["kanban", "milestone", "gap-report", "--json"],
                            ["kanban", "list", "--column", "todo", "--json", "--limit", "200"],
                            ["kanban", "list", "--column", "doing", "--json", "--limit", "200"]], observed
    brain_calls = [row for row in observed if row and row[0] == "brain"]
    assert brain_calls == [["brain", "get", "preference-feature-delivery-portfolio-admission",
                            "--type", "preference", "--json"]], brain_calls
    # Control: the same alert without --dry-run must reach our fake notifier
    # and persist state. Otherwise the negative assertions could pass vacuously.
    live = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=30)
    assert live.returncode == 0, live.stderr
    assert notifications.exists(), live.stdout
    assert (state / "state.json").exists(), "normal fixture run omitted state"
    assert (supply_dir / "supply-latest.json").exists(), "normal fixture run omitted supply"
print("ok factory-health isolated dry-run and notification control")
