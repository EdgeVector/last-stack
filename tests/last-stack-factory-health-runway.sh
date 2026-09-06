#!/usr/bin/env bash
# Fixture coverage for the supply-runway band.
#
# On 2026-09-06T03:21Z the live board read `ready=9 todo=9 doing=3 ships_h=6`
# and factory-health reported `factory=up` with no todo alert at all. The card
# producer (last-stack-papercut-reconciler) had bailed at 21:07Z with
# outcome=noop and filed zero cards, its next fire 11.6h away, while the pickup
# lanes kept consuming at 6/h. Nine cards was ninety minutes of runway.
#
# Nothing fired because both depth bands point at "too deep" (>=25, >=50) and
# todo_starved required todo==0 AND doing==0 — a post-mortem, not a warning.
# These cases pin the instrument that was missing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-factory-health"

python3 - "$bin" <<'PY'
import importlib.machinery
import importlib.util
import sys

spec = importlib.util.spec_from_loader(
    "fh", importlib.machinery.SourceFileLoader("fh", sys.argv[1])
)
fh = importlib.util.module_from_spec(spec)
sys.modules["fh"] = fh
spec.loader.exec_module(fh)

fails = []


def check(label, got, want):
    if got != want:
        fails.append(f"{label}: got {got!r}, want {want!r}")


def snap(**kw):
    s = fh.Snapshot(ts="2026-09-06T03:21:53Z")
    for k, v in kw.items():
        setattr(s, k, v)
    return s


def codes(snapshot, state=None, todo_cfg=None):
    """Run only the todo band so this asserts on ours alone."""
    cfg = {
        "todo": todo_cfg if todo_cfg is not None else {"enabled": True},
        "ready_buffer": {"enabled": False},
        "backlog": {"enabled": False},
        "ship_rate": {"enabled": False, "min_baseline_mean": 1.0},
        "doing": {"enabled": False},
        "ship_volume": {"enabled": False},
        "install": {"enabled": False},
        "closeout": {"enabled": False},
    }
    return [a.code for a in fh.evaluate(cfg, snapshot, {}, state if state is not None else {})]


def alerts(snapshot, state=None, todo_cfg=None):
    cfg = {
        "todo": todo_cfg if todo_cfg is not None else {"enabled": True},
        "ready_buffer": {"enabled": False},
        "backlog": {"enabled": False},
        "ship_rate": {"enabled": False, "min_baseline_mean": 1.0},
        "doing": {"enabled": False},
        "ship_volume": {"enabled": False},
        "install": {"enabled": False},
        "closeout": {"enabled": False},
    }
    return fh.evaluate(cfg, snapshot, {}, state if state is not None else {})


# ── the exact shape that went missing on 2026-09-06 ────────────────────────
# ready=9 draining at 6/h is 1.5h of runway: soft, and it needs two ticks.
live = snap(pickup_ready=9, todo=9, doing=3, ships_last_h=6.0, ships_per_hour_24h=2.6)
st = {}
check("first tick arms the streak, stays quiet", codes(live, st), [])
check("second tick fires soft", codes(live, st), ["todo_runway_soft"])

a = [x for x in alerts(live, {"streaks": {"todo_runway_soft": 5}}) if x.code == "todo_runway_soft"]
if not a:
    fails.append("soft alert missing on a primed streak")
else:
    d = a[0].detail
    for want in ("ready=9", "6.00/h", "runway"):
        if want not in d:
            fails.append(f"detail does not carry {want!r}: {d!r}")

# ── under an hour is hard, and hard does not wait for a streak ─────────────
check(
    "runway under 1h fires hard on the first tick",
    codes(snap(pickup_ready=3, todo=3, doing=2, ships_last_h=6.0, ships_per_hour_24h=6.0)),
    ["todo_runway_hard"],
)

# ── an idle factory has no runway problem, only an idle one ───────────────
# ship_rate_* owns that case; this band must stay silent below the baseline.
check(
    "silent below the ship-rate baseline",
    codes(snap(pickup_ready=1, todo=1, doing=0, ships_last_h=0.0, ships_per_hour_24h=0.0)),
    [],
)

# ── a long runway is silent no matter how thin the queue looks ────────────
check(
    "thin queue with a slow drain is fine",
    codes(snap(pickup_ready=6, todo=6, doing=1, ships_last_h=1.0, ships_per_hour_24h=1.0)),
    [],
)

# ── pickup_ready is the supply the lanes actually consume ─────────────────
# A deep todo full of unclaimable cards is not supply. Depth alone said this
# board was over-full; only two cards could be claimed.
deep = snap(pickup_ready=2, todo=40, doing=2, ships_last_h=4.0, ships_per_hour_24h=4.0)
got = codes(deep)
if "todo_runway_hard" not in got:
    fails.append(f"pickup_ready must beat todo depth: got {got!r}")
if "todo_depth_soft" not in got:
    fails.append(f"the existing too-deep band must still fire alongside: got {got!r}")

# An older board CLI returns no ready count; fall back to todo rather than
# reporting a runway of -1 hours.
fallback = alerts(
    snap(pickup_ready=-1, todo=4, doing=1, ships_last_h=6.0, ships_per_hour_24h=6.0)
)
hard = [x for x in fallback if x.code == "todo_runway_hard"]
if not hard:
    fails.append("no fallback to todo when pickup_ready is unknown")
elif "todo=4" not in hard[0].detail:
    fails.append(f"fallback does not name todo as the source: {hard[0].detail!r}")

# ── the last completed hour beats the 24h mean ────────────────────────────
# A factory that just accelerated drains on the new rate, not the old average.
check(
    "recent rate drives the runway, not the 24h mean",
    codes(snap(pickup_ready=4, todo=4, doing=1, ships_last_h=8.0, ships_per_hour_24h=1.2)),
    ["todo_runway_hard"],
)
# With no hourly bucket yet, the 24h mean is the fallback.
check(
    "24h mean is used when the hourly bucket is empty",
    codes(snap(pickup_ready=3, todo=3, doing=1, ships_last_h=0.0, ships_per_hour_24h=6.0)),
    ["todo_runway_hard"],
)

# ── an empty queue belongs to todo_starved, not to runway ─────────────────
empty = codes(snap(pickup_ready=0, todo=0, doing=3, ships_last_h=6.0, ships_per_hour_24h=6.0))
check("empty queue is todo_starved only", empty, ["todo_starved"])

# todo_starved must not wait for the last in-flight card to land. That is the
# only moment a refill can still keep the lanes busy.
if "todo_starved" not in empty:
    fails.append("todo_starved still requires doing==0")

# ── config switches ───────────────────────────────────────────────────────
check(
    "runway_enabled=false silences only the runway band",
    codes(live, {}, {"enabled": True, "runway_enabled": False}),
    [],
)
check(
    "todo band disabled silences everything here",
    codes(live, {}, {"enabled": False}),
    [],
)
check(
    "thresholds are configurable",
    codes(
        snap(pickup_ready=9, todo=9, doing=1, ships_last_h=6.0, ships_per_hour_24h=6.0),
        {},
        {"enabled": True, "runway_hard_hours": 2.0},
    ),
    ["todo_runway_hard"],
)

# ── the streak resets when supply recovers ────────────────────────────────
st2 = {}
codes(live, st2)
check("streak armed", int(st2["streaks"]["todo_runway_soft"]), 1)
codes(snap(pickup_ready=30, todo=30, doing=1, ships_last_h=6.0, ships_per_hour_24h=6.0), st2)
check("streak cleared by a healthy tick", int(st2["streaks"]["todo_runway_soft"]), 0)

if fails:
    for f in fails:
        print("FAIL " + f, file=sys.stderr)
    sys.exit(1)
print("ok factory-health runway band")
PY

echo "ok last-stack-factory-health-runway"
