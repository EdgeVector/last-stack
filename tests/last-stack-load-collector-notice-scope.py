#!/usr/bin/env python3
"""Every alert posts a notice labelled with ITS OWN subject, not one hard-coded label.

fire() used to build `--kind other --system lastdbd` with no severity hint for all
eleven rules. Four of them are not about lastdbd: fleet_freeze_watchdog_down is
about the routines scheduler, and the three host_* rules are about the host. The
measured consequence, 2026-10-02: the only notices on the timeline saying the
routines fleet-freeze watchdog had been silenced read

    INFO other  systems=lastdbd  actor=last-stack-load-collector
    the routines fleet-freeze watchdog is not running for 2516 passes: the agent
    is launchctl-disabled (plist present and va

— wrong system, no severity, and a title cut mid-word at 120 chars.

The case that matters most here is the STRUCTURAL one: a rule added to
evaluate_alerts without a row in ALERT_SCOPE silently inherits the lastdbd label
again, which is exactly how this defect would come back.
"""
import importlib.machinery, importlib.util, io, os, re, tempfile

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(root, "bin", "last-stack-load-collector")
os.environ["LOAD_MON_DIR"] = tempfile.mkdtemp()

loader = importlib.machinery.SourceFileLoader("lc", SRC)
spec = importlib.util.spec_from_loader("lc", loader)
lc = importlib.util.module_from_spec(spec)
loader.exec_module(lc)

KINDS = {"upgrade", "restart", "deploy", "config", "cutover", "other"}
SEVS = {"info", "warn"}


def executing_alert_names():
    """The alert names evaluate_alerts actually fires — read from what executes.

    Two shapes: rows of the `checks` table (`("name", st[...] >= N, msg)`) and the
    one unconditional `fire("lastdbd_restarted", ...)`.
    """
    body = io.open(SRC, encoding="utf-8").read().split("def evaluate_alerts")[1]
    return set(re.findall(r'\(\s*"([a-z0-9_]+)",\s*st\[', body)) | set(
        re.findall(r'fire\(\s*"([a-z0-9_]+)"', body))


# 1. STRUCTURAL: every rule that executes declares its own scope. A new rule with
#    no row here would fall back to the lastdbd label and reintroduce the defect.
names = executing_alert_names()
assert len(names) >= 11, "name enumeration found only %d rules — did the table shape change?" % len(names)
missing = sorted(names - set(lc.ALERT_SCOPE))
assert not missing, "alert(s) fire with no ALERT_SCOPE row, so they post as lastdbd: %s" % missing
stale = sorted(set(lc.ALERT_SCOPE) - names)
assert not stale, "ALERT_SCOPE rows for alerts that no longer fire: %s" % stale

# 2. Every row is sayable by `situations notice` — a bad kind or hint is rejected
#    by the CLI, and fire() detaches, so the failure would be invisible at runtime.
for name, (systems, kind, sev) in lc.ALERT_SCOPE.items():
    assert isinstance(systems, tuple) and systems, name
    assert all(s and isinstance(s, str) for s in systems), name
    assert kind in KINDS, "%s: kind %r is not one of %s" % (name, kind, sorted(KINDS))
    assert sev in SEVS, "%s: severity-hint %r is not one of %s" % (name, sev, sorted(SEVS))

# 3. The routines-scheduler alert is filed against routinesd, NOT lastdbd. This is
#    the 2026-10-02 misdirection: an operator filtering the timeline by system
#    looked under routines and the notice was under lastdbd.
systems, kind, sev = lc.alert_scope("fleet_freeze_watchdog_down")
assert systems == ("routinesd",), systems
assert "lastdbd" not in systems, "a silenced routines watchdog must not be filed against lastdbd"
assert sev == "warn", "the only out-of-fleet alarm being off is not an INFO"

# 4. The three host-pressure rules are about the host, not the database.
for name in ("host_swap_high", "host_load_high", "host_process_hog"):
    assert lc.alert_scope(name)[0] == ("host",), name

# 5. A restart is the `restart` kind, which the CLI has and fire() never used.
assert lc.alert_scope("lastdbd_restarted")[1] == "restart"

# 6. Refusing work / unreportable is warn; a threshold crossing is info.
for name in ("lastdb_persist_lanes_unhealthy", "node_unresponsive", "lastdb_governor_purge_failed"):
    assert lc.alert_scope(name)[2] == "warn", name
for name in ("host_swap_high", "lastdbd_cpu_high", "lastdbd_footprint_high",
             "lastdb_cold_group_near_cap", "lastdb_sync_degraded"):
    assert lc.alert_scope(name)[2] == "info", name

# 7. An unknown name must NOT raise: an alert path never costs the sample. It
#    keeps the pre-table behaviour, and case 1 is what forbids shipping one.
assert lc.alert_scope("some_rule_added_later") == (("lastdbd",), "other", "info")

# 8. The title is cut on a word boundary. The real 2026-10-02 message, which the
#    old `msg[:120]` rendered as "...plist present and va".
LIVE = ("the routines fleet-freeze watchdog is not running for 2516 passes: the agent is "
        "launchctl-disabled (plist present and valid); `launchctl enable gui/501/"
        "com.edgevector.routines-freeze-watch` then bootstrap it (while it is down, a "
        "scheduler freeze is reported by nothing)")
t = lc.headline(LIVE)
assert len(t) <= 120, len(t)
assert t.endswith("…"), t
assert t.startswith("the routines fleet-freeze watchdog is not running"), t
assert not t.endswith("va…"), "still cutting mid-word: %r" % t
assert "and va" not in t, "still cutting mid-word: %r" % t
assert LIVE.startswith(t[:-1]), "the title must be a prefix of the summary: %r" % t
assert " ".join(t[:-1].split()) == t[:-1], "title must be one line"

# A short message is passed through untouched, with no ellipsis.
assert lc.headline("lastdbd restarted: pid 1 -> 2 (node up 3s)") == \
    "lastdbd restarted: pid 1 -> 2 (node up 3s)"
# A newline in a message would break the one-line title contract.
assert lc.headline("two\nlines here") == "two lines here"

# 9. The built argv carries every label, repeats --system, and keeps the FULL
#    message in --summary even when the title elided it.
argv = lc.notice_argv("/bin/situations", "fleet_freeze_watchdog_down", LIVE)
assert argv[:2] == ["/bin/situations", "notice"], argv[:2]
assert argv[argv.index("--system") + 1] == "routinesd"
assert argv[argv.index("--severity-hint") + 1] == "warn"
assert argv[argv.index("--kind") + 1] == "other"
assert argv[argv.index("--summary") + 1] == LIVE, "the summary must not be truncated"
assert argv[argv.index("--actor") + 1] == "last-stack-load-collector"
assert "lastdbd" not in argv

# Multi-system rows emit one --system per name rather than a joined string.
saved = dict(lc.ALERT_SCOPE)
try:
    lc.ALERT_SCOPE["two_systems"] = (("host", "lastdbd"), "other", "info")
    a = lc.notice_argv("/bin/situations", "two_systems", "x")
    assert [a[i + 1] for i, v in enumerate(a) if v == "--system"] == ["host", "lastdbd"], a
finally:
    lc.ALERT_SCOPE.clear()
    lc.ALERT_SCOPE.update(saved)

# 10. fire() must build the notice through notice_argv, not inline labels again.
fire_src = io.open(SRC, encoding="utf-8").read().split("def fire(")[1].split("\ndef ")[0]
assert "notice_argv(" in fire_src, "fire() no longer routes through notice_argv"
for banned in ('"--system", "lastdbd"', 'msg[:120]'):
    assert banned not in fire_src, "fire() hard-codes a label again: %s" % banned

print("ok last-stack-load-collector-notice-scope")
