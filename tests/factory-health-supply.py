#!/usr/bin/env python3
"""Supply per admitted North Star: jam detection, named reasons, 2-pass alarm.

Regression for 2026-09-26: the Primary North Star had zero runnable cards for
hours. Every routine said "healthy" and factory-health only said
todo_runway_hard. This test drives the pure supply functions with a canned
gap-report, canned card lists and a canned admission record, then drives the
real CLI twice against stubs to prove the consecutive-pass alarm and its reset.
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

command = Path(__file__).resolve().parents[1] / "bin" / "last-stack-factory-health"
spec = importlib.util.spec_from_loader(
    "factory_health", importlib.machinery.SourceFileLoader("factory_health", str(command))
)
fh = importlib.util.module_from_spec(spec)
sys.modules["factory_health"] = fh
spec.loader.exec_module(fh)

PRIMARY = "north-star-fixture-primary"
SECONDARY = "north-star-fixture-secondary"
BACKFILL = "north-star-fixture-backfill"

ADMISSION_BODY = f"""# Feature delivery portfolio admission

Policy-Version: 14
Primary: {PRIMARY}
Secondary: {SECONDARY}
Backfill: `{BACKFILL}`
Paused: north-star-other, all-other-feature-north-stars
"""


def ms(slug, ns, status, reason, **extra):
    row = {"slug": slug, "north_star": ns, "status": status, "reason": reason,
           "state": extra.pop("state", "active"), "blocked_backlog": [],
           "has_proof_card": False, "proof_passing": False}
    row.update(extra)
    return row


GAP_REPORT = {
    "milestones": [
        # Primary: every open milestone is stuck -> jammed.
        ms("p-release-proof", PRIMARY, "idle_blocked",
           "backlog Kind:pr exist but all are held, hollow, missing Repo, or dep-blocked",
           blocked_backlog=["p-held-card", "p-dep-card"]),
        ms("p-terminal-proof", PRIMARY, "proof_pending",
           "implementation Kind:pr done; terminal proof still pending",
           has_proof_card=True, proof_passing=False),
        ms("p-planned", PRIMARY, "blocked", "milestone state is planned", state="planned"),
        ms("p-empty", PRIMARY, "idle_empty", "no Kind:pr cards"),
        ms("p-done", PRIMARY, "complete", "milestone is complete"),
        # Secondary: one in_flight milestone -> not jammed even with zero cards.
        ms("s-wave", SECONDARY, "in_flight", "live Kind:pr in todo=0 doing=1"),
        # Backfill: no milestones but a runnable todo card (mapped by milestone).
        ms("b-wave", BACKFILL, "idle_promoteable", "promoteable backlog"),
        ms("other", "north-star-other", "idle_blocked", "not admitted"),
    ]
}

CARDS = {
    "p-held-card": {"slug": "p-held-card", "block_status": "needs_human",
                    "block_reason": "waiting on Tom: schema budget", "blockedBy": []},
    "p-dep-card": {"slug": "p-dep-card", "block_status": "", "block_reason": "",
                   "blockedBy": ["p-upstream"]},
}
lookups = []


def lookup(slug):
    lookups.append(slug)
    return CARDS.get(slug)


failures = []


def check(label, cond, detail=""):
    if not cond:
        failures.append(f"{label}: {detail}")


# ── admission parse ─────────────────────────────────────────────────────────
admitted = fh.parse_admission(ADMISSION_BODY)
check("admission primary", admitted["primary"] == PRIMARY, admitted)
check("admission secondary", admitted["secondary"] == SECONDARY, admitted)
check("admission backfill parsed", admitted["backfill"] == BACKFILL, admitted)
no_backfill = fh.parse_admission(f"Primary: {PRIMARY}\nSecondary: {SECONDARY}\n")
check("backfill absent -> None", no_backfill["backfill"] is None, no_backfill)
placeholder = fh.parse_admission(f"Primary: {PRIMARY}\nBackfill: none\n")
check("backfill placeholder -> None", placeholder["backfill"] is None, placeholder)
check("secondary absent -> None", placeholder["secondary"] is None, placeholder)

# ── jam detected with named reasons ─────────────────────────────────────────
todo = [
    {"slug": "b-card", "kind": "pr", "north_star": "", "milestone": "b-wave"},
    {"slug": "p-ops", "kind": "ops", "north_star": PRIMARY, "milestone": "p-empty"},
]
doing = [{"slug": "other-card", "kind": "pr", "north_star": "north-star-other"}]
supply = fh.compute_supply(admitted, GAP_REPORT, todo, doing, card_lookup=lookup)
runnable = supply["runnable_by_ns"]
check("primary 0 cards (non-pr ignored)", runnable[PRIMARY]["cards"] == 0, runnable)
check("primary decomposable counts idle_empty", runnable[PRIMARY]["decomposable_milestones"] == 1, runnable)
check("secondary active milestone", runnable[SECONDARY]["active_milestones"] == 1, runnable)
check("backfill card via milestone map", runnable[BACKFILL]["cards"] == 1, runnable)
check("non-admitted NS excluded", "north-star-other" not in runnable, runnable)
jam_ns = [j["ns"] for j in supply["jammed"]]
check("only primary jammed", jam_ns == [PRIMARY], jam_ns)
named = {m["slug"]: m for m in supply["jammed"][0]["milestones"]}
check("terminal milestone not named", "p-done" not in named, named)
check("all open milestones named", set(named) == {"p-release-proof", "p-terminal-proof", "p-planned", "p-empty"}, named)
rel = named["p-release-proof"]["reason"]
check("idle_blocked names held card + reason", "p-held-card (needs_human: waiting on Tom: schema budget)" in rel, rel)
check("idle_blocked names dep-blocked card", "p-dep-card (dep-blocked by p-upstream)" in rel, rel)
check("idle_blocked status kept", named["p-release-proof"]["status"] == "idle_blocked", named)
check("proof_pending says FAIL", "proof card FAIL" in named["p-terminal-proof"]["reason"], named)
check("planned skip names state", "state=planned" in named["p-planned"]["reason"], named)
check("lookups bounded to blocked cards", lookups == ["p-held-card", "p-dep-card"], lookups)
check("heartbeat runnable token",
      fh.format_runnable(supply) == f"{PRIMARY}:0/0/1,{SECONDARY}:0/1/0,{BACKFILL}:1/1/0",
      fh.format_runnable(supply))
check("heartbeat jammed token", fh.format_jammed(supply) == PRIMARY, fh.format_jammed(supply))

# Lookup budget: zero budget never calls kanban show.
lookups.clear()
fh.compute_supply(admitted, GAP_REPORT, todo, doing, card_lookup=lookup, max_lookups=0)
check("zero lookup budget", lookups == [], lookups)

# ── not jammed when one in_flight milestone ─────────────────────────────────
healed = json.loads(json.dumps(GAP_REPORT))
healed["milestones"][0]["status"] = "in_flight"
supply_ok = fh.compute_supply(admitted, healed, todo, doing, card_lookup=lookup)
check("in_flight clears jam", supply_ok["jammed"] == [], supply_ok["jammed"])
check("no jam -> no supply alert", fh.evaluate_supply({}, supply_ok, "", 0) == [], "")

# ── consecutive counter ─────────────────────────────────────────────────────
streaks, n = fh.advance_jam_streaks({}, [PRIMARY])
check("first pass = 1", n == 1 and streaks == {PRIMARY: 1}, (streaks, n))
streaks, n = fh.advance_jam_streaks({"jam_streaks": streaks}, [PRIMARY])
check("second pass = 2", n == 2 and streaks == {PRIMARY: 2}, (streaks, n))
streaks, n = fh.advance_jam_streaks({"jam_streaks": streaks}, [])
check("clear pass resets", n == 0 and streaks == {}, (streaks, n))
streaks, n = fh.advance_jam_streaks({"jam_streaks": {PRIMARY: 2}}, [SECONDARY])
check("new NS starts at 1, old NS dropped", n == 1 and streaks == {SECONDARY: 1}, (streaks, n))

first = fh.evaluate_supply({}, supply, "", 1)
check("pass 1 soft, not notifiable",
      [(a.severity, a.code, a.notify) for a in first] == [("soft", "supply_jam", False)], first)
second = fh.evaluate_supply({}, supply, "", 2)
check("pass 2 hard, notifiable",
      [(a.severity, a.code, a.notify) for a in second] == [("hard", "supply_jam_sustained", True)], second)
check("alarm names reasons", "p-held-card" in second[0].detail and "p-terminal-proof" in second[0].detail,
      second[0].detail)
unread = fh.evaluate_supply({}, None, "admission: missing", 0)
check("unreadable supply is never ok",
      [(a.severity, a.code, a.notify) for a in unread] == [("soft", "supply_unreadable", False)], unread)

# ── real CLI: two jammed passes page once, a clear pass resets ──────────────
with tempfile.TemporaryDirectory(prefix="factory-health-supply-") as directory:
    root = Path(directory)
    binaries = root / "bin"
    binaries.mkdir()
    fixtures = root / "fixtures"
    fixtures.mkdir()
    (fixtures / "gap.json").write_text(json.dumps(GAP_REPORT), encoding="utf-8")
    (fixtures / "admission.json").write_text(
        json.dumps({"slug": fh.ADMISSION_SLUG, "body": ADMISSION_BODY}), encoding="utf-8")
    (fixtures / "todo.json").write_text(json.dumps({"cards": todo, "total": 2, "truncated": False}))
    (fixtures / "doing.json").write_text(json.dumps({"cards": doing, "total": 1, "truncated": False}))
    notes = root / "notifications.jsonl"
    stub = binaries / "fixture-tool"
    stub.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
fx = Path(os.environ["FIXTURE_DIR"])
if name == "ra":
    with open(os.environ["FIXTURE_NOTES"], "a") as s:
        s.write(json.dumps(args) + "\\n")
    raise SystemExit(0)
if name == "brain" and args[:2] == ["get", "preference-feature-delivery-portfolio-admission"]:
    print((fx / "admission.json").read_text()); raise SystemExit(0)
if args == ["list", "--json", "--all"]:
    print(json.dumps([{"slug": "fixture-card", "column": "doing", "kind": "pr",
        "title": "t", "repo": "Fixture/example", "created_at": "2026-09-26T00:00:00Z",
        "first_doing_at": "2099-01-01T00:00:00Z"}]))
elif args == ["pickup", "status", "--json"]:
    print('{"ready":3}')
elif args == ["milestone", "gap-report", "--json"]:
    print((fx / "gap.json").read_text())
elif args[:3] == ["list", "--column", "todo"]:
    print((fx / "todo.json").read_text())
elif args[:3] == ["list", "--column", "doing"]:
    print((fx / "doing.json").read_text())
elif args[:1] == ["show"]:
    cards = json.loads(os.environ["FIXTURE_CARDS"])
    if args[1] not in cards:
        raise SystemExit(1)
    print(json.dumps(cards[args[1]]))
else:
    raise SystemExit(99)
''', encoding="utf-8")
    stub.chmod(0o755)
    for name in ("kanban", "fkanban", "ra", "lastgit", "last-stack-forge-api", "brain"):
        (binaries / name).symlink_to(stub.name)
    config = root / "config.toml"
    # Every non-supply band off so the verdict is the supply verdict alone.
    config.write_text('''[general]
factory_url = "file:///nonexistent-factory-health-fixture"
[notify]
enabled = true
quiet_hours = []
cooldown_s = 0
[auto_fix]
enabled = false
[ship_rate]
enabled = false
[doing]
enabled = false
[todo]
enabled = false
[ready_buffer]
enabled = false
[backlog]
enabled = false
[ship_volume]
enabled = false
[install]
enabled = false
[closeout]
enabled = false
[supply]
enabled = true
alarm_after_passes = 2
''', encoding="utf-8")
    supply_dir = root / "supply-state"
    env = {**os.environ, "HOME": str(root), "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
           "FACTORY_HEALTH_STATE_DIR": str(root / "state"),
           "FACTORY_HEALTH_SUPPLY_STATE_DIR": str(supply_dir),
           "FIXTURE_DIR": str(fixtures), "FIXTURE_NOTES": str(notes),
           "FIXTURE_CARDS": json.dumps(CARDS)}
    argv = [sys.executable, str(command), "--last-stack", str(root), "--config", str(config)]

    def one_pass(label):
        proc = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=60)
        check(f"{label} exit", proc.returncode == 0, proc.stderr)
        line = proc.stdout.splitlines()[0] if proc.stdout else ""
        latest = json.loads((supply_dir / "supply-latest.json").read_text())
        return line, latest

    line1, latest1 = one_pass("pass1")
    check("pass1 verdict not ok", " soft " in line1 and "codes=supply_jam " in line1, line1)
    check("pass1 heartbeat fields", f"jammed={PRIMARY} jam_passes=1" in line1
          and f"runnable_by_ns={PRIMARY}:0/0/1," in line1, line1)
    check("pass1 did not page", not notes.exists(), "notified on first pass")
    check("latest counter 1", latest1["consecutive_jam_passes"] == 1, latest1)
    check("latest admitted", latest1["admitted"] == {"primary": PRIMARY, "secondary": SECONDARY,
                                                     "backfill": BACKFILL}, latest1)
    check("latest jammed shape", latest1["jammed"][0]["ns"] == PRIMARY
          and {"slug", "status", "reason"} <= set(latest1["jammed"][0]["milestones"][0]), latest1)
    check("latest has ts + runnable", latest1["ts"] and PRIMARY in latest1["runnable_by_ns"], latest1)

    line2, latest2 = one_pass("pass2")
    check("pass2 hard", " hard " in line2 and "supply_jam_sustained" in line2, line2)
    check("pass2 counter 2", latest2["consecutive_jam_passes"] == 2 and "jam_passes=2" in line2, line2)
    sent = [json.loads(x) for x in notes.read_text().splitlines()] if notes.exists() else []
    check("pass2 paged once", len(sent) == 1, sent)
    if sent:
        msg = sent[0][1]
        check("page names jam reasons", "p-held-card" in msg and "waiting on Tom" in msg
              and "p-terminal-proof" in msg and "proof card FAIL" in msg, msg)

    (fixtures / "gap.json").write_text(json.dumps(healed), encoding="utf-8")
    line3, latest3 = one_pass("pass3")
    check("pass3 clear -> ok", " ok " in line3 and "jammed=none jam_passes=0" in line3, line3)
    check("pass3 counter reset", latest3["consecutive_jam_passes"] == 0 and latest3["jammed"] == [], latest3)
    state3 = json.loads((supply_dir / "supply-state.json").read_text())
    check("state jam set cleared", state3["jammed"] == [] and state3["jam_streaks"] == {}, state3)

if failures:
    for f in failures:
        print("FAIL " + f)
    raise SystemExit(1)
print("ok factory-health supply per admitted North Star")
