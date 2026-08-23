#!/usr/bin/env bash
# Fixture coverage for the backlog black-hole band.
#
# On 2026-08-08 the live board read `pickup-ready: 2 of 78` with 21 Kind:pr
# cards stranded in backlog — ungated, dependency-free, and milestone-less, so
# fkanban's live-PR milestone gate refused every one of them into todo. No
# factory-health band noticed: ship rate looked plausible and todo depth read as
# merely thin. These cases pin the instrument that was missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-factory-health"

python3 - "$bin" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_loader(
    "fh", importlib.machinery.SourceFileLoader("fh", sys.argv[1])
)
fh = importlib.util.module_from_spec(spec)
# dataclasses resolves field types through sys.modules[cls.__module__]; a module
# built by module_from_spec is not registered there yet, so @dataclass raises
# AttributeError on None. Register before exec.
sys.modules["fh"] = fh
spec.loader.exec_module(fh)

import time as _t

# age_hours clamps at 0, so `now` has to be a real epoch or every fixture reads
# as brand new and the age filter silently drops it.
NOW = _t.time()
OLD = "2020-01-01T00:00:00Z"  # far past → age_hours returns a large number


def card(slug, **kw):
    c = {
        "slug": slug,
        "column": "backlog",
        "kind": "pr",
        "block_status": "none",
        "deps": [],
        "milestone": "",
        "updated_at": OLD,
        "position": "1",
    }
    c.update(kw)
    return c


def slugs(cards, min_age_h=3.0):
    return [s for s, _ in fh.unreachable_backlog_cards(cards, NOW, min_age_h)]


fails = []


def check(label, got, want):
    if got != want:
        fails.append(f"{label}: got {got!r}, want {want!r}")


# The exact shape that went missing.
check("black hole", slugs([card("papercut-ops-terminal-single-board-list-poll")]),
      ["papercut-ops-terminal-single-board-list-poll"])

# Empty/unknown kind normalizes to pr, matching fkanban's normalizeKind — the
# 2026-08-08 cards had kind unset on the wire.
check("empty kind counts as pr", slugs([card("no-kind", kind="")]), ["no-kind"])
check("unknown kind counts as pr", slugs([card("weird", kind="banana")]), ["weird"])

# Every legitimate reason to sit in backlog must stay silent.
check("has milestone", slugs([card("ok", milestone="ms-real")]), [])
check("needs_human", slugs([card("held", block_status="needs_human")]), [])
check("deferred", slugs([card("parked", block_status="deferred")]), [])
check("waiting on an unfinished dep", slugs([card("waiter", deps=["x"], missingDeps=["x"])]), [])
check("blocked flag", slugs([card("blocked-card", deps=["x"], blocked=True)]), [])
# A SATISFIED dep is not a wait. Three of the 19 cards stranded on 2026-08-08
# carried deps with missingDeps=[] and blocked=false; excusing them on the raw
# `deps` list alone is exactly how they stayed invisible.
check("satisfied deps still flagged",
      slugs([card("done-deps", deps=["x"], missingDeps=[], blocked=False)]), ["done-deps"])
# Older CLI with neither derived field: over-report rather than miss.
check("legacy deps-only row", slugs([card("legacy", deps=["x"])]), [])
for k in ("tracker", "capstone", "validation", "program", "registry"):
    check(f"kind {k}", slugs([card(f"k-{k}", kind=k)]), [])
check("not backlog", slugs([card("in-todo", column="todo")]), [])

# Fresh cards are the normal file-then-stamp flow, not a black hole.
fresh = card("just-filed", updated_at=_t.strftime("%Y-%m-%dT%H:%M:%SZ", _t.gmtime()))
check("fresh card ignored", fh.unreachable_backlog_cards([fresh], _t.time(), 3.0), [])

# Oldest first, and the snapshot carries count + oldest age + a capped sample.
many = [card(f"c{i}") for i in range(7)]
snap, _ = fh.build_snapshot(many, None, True, parked_min_age_h=3.0)
check("snapshot count", snap.parked_ungated, 7)
check("sample capped at 5", len(snap.parked_ungated_slugs), 5)
if snap.parked_ungated_oldest_h <= 0:
    fails.append("oldest age not populated")

# The band fires, names the cards, and escalates past hard_count.
def codes_for(cfg_backlog, snapshot):
    cfg = {
        "backlog": cfg_backlog,
        # Silence every other band so this asserts on ours alone.
        "ship_rate": {"enabled": False},
        "doing": {"enabled": False},
        "todo": {"enabled": False},
        "ship_volume": {"enabled": False},
        "install": {"enabled": False},
        "closeout": {"enabled": False},
    }
    return fh.evaluate(cfg, snapshot, {}, {})


band = {"enabled": True, "soft_count": 1, "hard_count": 10, "min_age_h": 3.0}
alerts = codes_for(band, snap)
check("soft fires at 7", [a.code for a in alerts], ["backlog_unreachable_soft"])
if "c0" not in alerts[0].detail:
    fails.append(f"detail does not name the stranded cards: {alerts[0].detail!r}")
if "live_pr_milestone_required" not in alerts[0].detail:
    fails.append("detail does not name the gate that refuses them")

snap_hard, _ = fh.build_snapshot([card(f"h{i}") for i in range(12)], None, True, 3.0)
check("hard fires at 12", [a.code for a in codes_for(band, snap_hard)],
      ["backlog_unreachable_hard"])

clean, _ = fh.build_snapshot([card("ok", milestone="ms-real")], None, True, 3.0)
check("silent when healthy", [a.code for a in codes_for(band, clean)], [])
check("respects enabled=false",
      [a.code for a in codes_for({"enabled": False}, snap)], [])

# Deploy-parked doing cards are in-flight, not factory-stuck.
parked = {
    "slug": "invite-link",
    "column": "doing",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "position": str(int((NOW - 20 * 3600) * 1000)),
}
live_pr = {
    "slug": "open-pr",
    "column": "doing",
    "tags": ["p1"],
    "pr_url": "http://localhost:3300/EdgeVector/fold/pulls/1478",
    "position": str(int((NOW - 3 * 3600) * 1000)),
}
check("parked is parked", fh.is_deploy_parked(parked), True)
check("open pr is not parked", fh.is_deploy_parked(live_pr), False)
check("actionable drops parked",
      [c["slug"] for c in fh.actionable_doing([parked, live_pr])], ["open-pr"])
upgrade = dict(parked)
upgrade["slug"] = "needs-safe-upgrade"
upgrade["tags"] = ["needs-safe-upgrade"]
check("needs-safe-upgrade is parked", fh.is_deploy_parked(upgrade), True)
awaiting = dict(parked)
awaiting["slug"] = "awaiting-validation"
awaiting["tags"] = ["awaiting-validation"]
check("awaiting-validation is parked", fh.is_deploy_parked(awaiting), True)
check("actionable drops extra park tags",
      [c["slug"] for c in fh.actionable_doing([parked, live_pr, upgrade, awaiting])],
      ["open-pr"])

if fails:
    for f in fails:
        print("FAIL " + f, file=sys.stderr)
    sys.exit(1)
print("ok factory-health backlog band")
PY

echo "ok last-stack-factory-health-backlog"
