#!/usr/bin/env bash
# Factory-health must read the merge-derived ship source and never invent a zero.
#
# Overnight 2026-09-03/04 the meter reported ships_h=0 in six hours that merged
# 4, 4, 4, 5, 3, 2 CRs. The dashboard counted surviving done cards (the reaper
# deletes those), and factory-health's 4s client timeout plus board fallback
# invented the same zero. These cases pin the consumer contract.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-factory-health"

python3 - "$bin" <<'PY'
import importlib.machinery
import importlib.util
import json
import socket
import sys
from datetime import datetime, timezone
from urllib.error import URLError

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


def ts(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()


def volume_codes(snapshot, history=None):
    cfg = {
        "todo": {"enabled": False},
        "ready_buffer": {"enabled": False},
        "backlog": {"enabled": False},
        "ship_rate": {"enabled": False, "min_baseline_mean": 1.0},
        "doing": {"enabled": False},
        "ship_volume": {
            "enabled": True,
            "min_history_points": 6,
            "soft_ratio": 0.5,
            "hard_ratio": 0.25,
        },
        "install": {"enabled": False},
        "closeout": {"enabled": False},
        "notify": {"quiet_hours": []},
        "general": {},
    }
    hist = history if history is not None else [{"ships_24h": 80} for _ in range(8)]
    return [
        a.code
        for a in fh.evaluate(cfg, snapshot, {}, {"history": hist, "streaks": {}})
    ]


# ── timeout budget sits above the measured 13.07s cold call ───────────────
check("default factory timeout is above 13.07s", fh.DEFAULT_FACTORY_TIMEOUT_S >= 14.0, True)
check("config default matches the constant", fh.DEFAULT_FACTORY_TIMEOUT_S, 20.0)

# ── timeout vs refused ────────────────────────────────────────────────────
check("TimeoutError is a timeout", fh._is_timeout_exc(TimeoutError("timed out")), True)
check("socket.timeout is a timeout", fh._is_timeout_exc(socket.timeout("timed out")), True)
check(
    "URLError wrapping socket.timeout is a timeout",
    fh._is_timeout_exc(URLError(socket.timeout("timed out"))),
    True,
)
check(
    "connection refused is not a timeout",
    fh._is_timeout_exc(URLError(ConnectionRefusedError("refused"))),
    False,
)
check("ConnectionRefusedError is refused", fh._is_refused_exc(ConnectionRefusedError()), True)
check(
    "timeout label is not down",
    fh.factory_status_label(fh.FactoryFetch(kind="timeout")),
    "timeout",
)
check(
    "refused label is not down",
    fh.factory_status_label(fh.FactoryFetch(kind="refused")),
    "refused",
)
check("ok label is up", fh.factory_status_label(fh.FactoryFetch(kind="ok", data={})), "up")

# ── old card-based velocity is not merge-derived ──────────────────────────
old = {
    "velocity": {
        "ships": {"h24": {"count": 0, "perHour": 0, "hours": 24}},
        "hourly": [{"hourAgo": 1, "ships": 0}],
    }
}
check("old card meter is not merge-derived", fh.dashboard_is_merge_derived(old["velocity"]), False)
check("old card meter is not consumed", fh.ships_from_dashboard(old, True), None)

# ── merge-derived dashboard, including unavailable ────────────────────────
merge_ok = {
    "velocity": {
        "available": True,
        "unavailableRepos": [],
        "boardCompletions": {},
        "ships": {
            "h24": {
                "count": 22,
                "perHour": 0.92,
                "hours": 24,
                "available": True,
            }
        },
        "hourly": [
            {"hourAgo": 1, "ships": 4, "available": True},
            {"hourAgo": 0, "ships": 1, "available": True},
        ],
    }
}
got = fh.ships_from_dashboard(merge_ok, True)
check("dashboard last_h", got.last_h if got else None, 4.0)
check("dashboard h24", got.h24 if got else None, 22.0)
check("dashboard available", got.available if got else None, True)
check("dashboard source", got.source if got else None, "dashboard")

merge_missing = {
    "velocity": {
        "available": False,
        "unavailableRepos": ["last-stack"],
        "ships": {
            "h24": {
                "count": None,
                "perHour": None,
                "hours": 24,
                "available": False,
            }
        },
        "hourly": [{"hourAgo": 1, "ships": None, "available": False}],
    }
}
miss = fh.ships_from_dashboard(merge_missing, True)
check("unavailable last_h is None not 0", miss.last_h if miss else "no-read", None)
check("unavailable h24 is None not 0", miss.h24 if miss else "no-read", None)
check("unavailable available=false", miss.available if miss else None, False)

# ── board done cards must not become ships ────────────────────────────────
done_cards = [
    {
        "slug": "reaped-looking",
        "column": "done",
        "done_at": "2026-09-04T08:10:00Z",
        "updated_at": "2026-09-04T08:10:00Z",
    }
]
snap, _meta = fh.build_snapshot(
    done_cards,
    None,
    True,
    ship_read=fh.ShipRead.missing("unavailable"),
)
check("board fallback gone: last_h unavailable", snap.ships_last_h, None)
check("board fallback gone: h24 unavailable", snap.ships_24h, None)
check("board fallback gone: available false", snap.ships_available, False)

# ── lastgit rows count merges, not cards ──────────────────────────────────
rows = [
    {"repo": "fold", "merged_at": "2026-09-04T04:48:12Z", "merge_oid": "abc"},
    {"repo": "loom", "merged_at": "2026-09-04T04:10:00Z", "merge_oid": "def"},
]
now = ts("2026-09-04T06:05:00Z")
times = [fh.parse_merge_ts(r["merged_at"]) for r in rows]
read = fh.ships_from_merge_times(times, now=now, use_completed_hour=True, source="lastgit")
check("lastgit completed-hour count", read.last_h, 2.0)
check("lastgit source", read.source, "lastgit")


def stub_lastgit_only(cmd, timeout=0):
    if cmd and cmd[0] == "lastgit":
        return 0, json.dumps(rows), ""
    return 1, "", "no forgejo in this stub"


resolved = fh.resolve_ships(None, True, now=now, runner=stub_lastgit_only)
check("resolve uses lastgit when dashboard is absent", resolved.source, "lastgit")
check("resolve lastgit last_h", resolved.last_h, 2.0)

# lastgit empty + forgejo fail → unavailable, not a measured zero
def stub_both_fail(cmd, timeout=0):
    if cmd and cmd[0] == "lastgit":
        return 0, "[]", ""
    return 1, "", "forge down"


empty = fh.resolve_ships(None, True, now=now, runner=stub_both_fail)
check("empty lastgit + failed forgejo is unavailable", empty.source, "unavailable")
check("empty lastgit + failed forgejo last_h is None", empty.last_h, None)
check("empty lastgit + failed forgejo available", empty.available, False)


def stub_lastgit_fail(cmd, timeout=0):
    return 1, "", "lastgit disabled"


both_fail = fh.resolve_ships(None, True, now=now, runner=stub_lastgit_fail)
check("both CLIs failed → unavailable", both_fail.source, "unavailable")
check("both CLIs failed → no invented zero", both_fail.h24, None)

# ── replay of the six overnight hours that paged ships_h=0 ────────────────
# Heartbeats vs real merges that hour (papercut 2026-09-04):
# 22Z:4  23Z:4  00Z:4  04Z:5  07Z:3  08Z:2
histogram = {
    "2026-09-03T22:00:00Z": 4,
    "2026-09-03T23:00:00Z": 4,
    "2026-09-04T00:00:00Z": 4,
    "2026-09-04T04:00:00Z": 5,
    "2026-09-04T07:00:00Z": 3,
    "2026-09-04T08:00:00Z": 2,
}
replay_ts = []
for hour, n in histogram.items():
    start = ts(hour)
    for i in range(n):
        replay_ts.append(start + 60 * (i + 1))
replay_hours = []
for hour in histogram:
    start = ts(hour)
    end = start + 3600
    replay_hours.append(sum(1 for t in replay_ts if start <= t < end))
check("replay six flagged hours", replay_hours, [4, 4, 4, 5, 3, 2])

# Counting from a heartbeat inside 04Z (04:20) with completed-hour=False
# (the hour containing the heartbeat) must read 5, not 0.
hb_now = ts("2026-09-04T04:20:26Z")
inside = fh.ships_from_merge_times(
    replay_ts, now=hb_now, use_completed_hour=False, source="lastgit"
)
check("04Z heartbeat hour reads 5, not 0", inside.last_h, 5.0)

# ── unavailable must not raise ship_volume_* ──────────────────────────────
missing_snap = fh.Snapshot(
    ts="2026-09-04T08:25:50Z",
    ships_last_h=None,
    ships_24h=None,
    ships_per_hour_24h=None,
    ships_available=False,
    ships_source="unavailable",
)
check("no ship_volume alert on unavailable", volume_codes(missing_snap), [])

zero_snap = fh.Snapshot(
    ts="2026-09-04T08:25:50Z",
    ships_last_h=0.0,
    ships_24h=0.0,
    ships_per_hour_24h=0.0,
    ships_available=True,
    ships_source="dashboard",
)
# Measured zero against a fat history still alerts — that is a real collapse.
vol = volume_codes(zero_snap)
check("measured zero still can alert", "ship_volume_hard" in vol, True)

# ── heartbeat formatter ───────────────────────────────────────────────────
check("fmt unavailable", fh.fmt_ships(None), "unavailable")
check("fmt measured zero", fh.fmt_ships(0.0), "0")
check("fmt four", fh.fmt_ships(4.0), "4")

if fails:
    print("FAIL last-stack-factory-health-ship-meter")
    for f in fails:
        print(" -", f)
    raise SystemExit(1)
print("ok last-stack-factory-health-ship-meter")
PY

echo "ok last-stack-factory-health-ship-meter"
