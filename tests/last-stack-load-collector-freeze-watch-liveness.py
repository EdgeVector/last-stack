#!/usr/bin/env python3
"""freeze_watch_down names each cause of a silent fleet-freeze watchdog, and stays quiet otherwise.

The watchdog (routines freeze-watch) is the only detector not dispatched by
routinesd, so it is the only one that can report a scheduler freeze — and it
cannot report its own absence. On 2026-10-02 it was launchctl-disabled at
00:44:45Z together with com.edgevector.routinesd, and the fleet sat at
active=0/81 for ~1h45m with nothing reporting it.

The case that MUST stay quiet is "no plist": the watchdog is optional, and an
alert there would fire forever on every host that never installed it.
"""
import importlib.machinery, importlib.util, os, stat, tempfile, time

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
tmp = tempfile.mkdtemp()
os.environ["LOAD_MON_DIR"] = tmp
LABEL = "com.edgevector.routines-freeze-watch"
plist = os.path.join(tmp, LABEL + ".plist")
log = os.path.join(tmp, "freeze-watch.out.log")
fake = os.path.join(tmp, "launchctl")
os.environ["LOAD_MON_FREEZE_WATCH_PLIST"] = plist
os.environ["LOAD_MON_FREEZE_WATCH_LOG"] = log
os.environ["LOAD_MON_LAUNCHCTL"] = fake
os.environ["LOAD_MON_FREEZE_WATCH_INTERVAL_SEC"] = "900"
# The latch-hazard check added 2026-10-03 reads the installed routines binary and
# two scheduler logs, and its real defaults are live host paths. What actually
# isolates THIS file from them is `now = 10 ** 7` below: every age it computes
# against a real log is negative, so the hazard reads "not blind" and returns
# None, and every case here exercises the plain "keep the enable advice" arm.
# These three overrides are belt-and-braces for a future case that wants a real
# clock. They are deliberately NOT presented as tested: a mutation probe removing
# all three comes back GREEN, because the fake clock alone is sufficient. Do not
# read that green as the hazard check being unreachable -- its matrix is
# tests/last-stack-load-collector-watchdog-latch-hazard.py, which uses time.time().
os.environ["LOAD_MON_ROUTINES_BIN"] = os.path.join(tmp, "absent-routines")
os.environ["LOAD_MON_ROUTINESD_LOG"] = os.path.join(tmp, "absent-routinesd.err.log")
os.environ["LOAD_MON_HEARTBEAT_LOG"] = os.path.join(tmp, "absent-heartbeats.log")

loader = importlib.machinery.SourceFileLoader("lc", os.path.join(root, "bin", "last-stack-load-collector"))
spec = importlib.util.spec_from_loader("lc", loader)
lc = importlib.util.module_from_spec(spec)
loader.exec_module(lc)


def set_launchctl(disabled_state, loaded):
    """A fake launchctl answering print-disabled and list the way the real one does."""
    dis = '\t\t"%s" => %s\n\t\t"com.edgevector.routinesd" => enabled\n' % (LABEL, disabled_state)
    lst = "12762\t-15\tcom.edgevector.load-collector\n" + ("99134\t0\t%s\n" % LABEL if loaded else "")
    with open(fake, "w") as f:
        f.write("#!/bin/sh\ncase \"$1\" in\n")
        f.write("print-disabled) cat <<'EOF'\n%sEOF\n;;\n" % dis)
        f.write("list) cat <<'EOF'\n%sEOF\n;;\nesac\n" % lst)
    os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)


now = 10 ** 7

# 1. No plist at all: the watchdog is not installed. NOT a fault.
set_launchctl("enabled", True)
assert not os.path.exists(plist)
assert lc.freeze_watch_down(now) is None, "an absent plist must never alert"

open(plist, "w").write("<plist/>")

# 2. launchctl-disabled — the 2026-10-02 incident. Names enable+bootstrap.
set_launchctl("disabled", False)
why = lc.freeze_watch_down(now)
assert why and "launchctl-disabled" in why, why
assert "launchctl enable" in why, why

# 3. Enabled but not loaded — a different repair (bootstrap, not enable).
set_launchctl("enabled", False)
why = lc.freeze_watch_down(now)
assert why and "not loaded" in why, why
assert "launchctl-disabled" not in why, "a booted-out agent is not a disabled one: %s" % why

# 4. Enabled, loaded, no log yet.
set_launchctl("enabled", True)
why = lc.freeze_watch_down(now)
assert why and "never written" in why, why

# 5. Enabled, loaded, log FRESH: the healthy case, and it must be silent.
open(log, "w").write("tick\n")
os.utime(log, (now - 60, now - 60))
assert lc.freeze_watch_down(now) is None, "a ticking watchdog must not alert"

# 6. Log stale past 2x the interval: loaded but producing nothing.
os.utime(log, (now - 1900, now - 1900))
why = lc.freeze_watch_down(now)
assert why and "has not grown" in why, why
# Exactly at the bound it is still quiet; the alert is for PAST two intervals.
os.utime(log, (now - 1800, now - 1800))
assert lc.freeze_watch_down(now) is None, "2x the interval exactly must not alert"

# 7. launchctl itself unavailable must not crash, and must not invent a fault.
# LAUNCHCTL is a module constant read at import, so set it on the module.
saved = lc.LAUNCHCTL
lc.LAUNCHCTL = os.path.join(tmp, "does-not-exist")
assert lc.launchctl_text(["list"]) == "", "a missing launchctl must read as empty, not raise"
os.utime(log, (now - 60, now - 60))
assert lc.freeze_watch_down(now) is None, \
    "with launchctl unreadable and the log fresh, there is no evidence of a fault"
lc.LAUNCHCTL = saved

# 8. The alert needs FW_CONSEC passes, and it reaches the alert table.
fired = []
lc.fire = lambda name, msg, now: fired.append((name, msg))
state = {}
lc.load_state = lambda: state
lc.save_state = lambda st: None
os.utime(log, (now - 100000, now - 100000))  # stale => down


def rec():
    return {"host": {"load": [1], "top": []}, "node": {"status": {"state": "ok", "vitals": {}}}}


lc.evaluate_alerts(rec(), now)
assert not [f for f in fired if f[0] == "fleet_freeze_watchdog_down"], "one pass must not fire"
lc.evaluate_alerts(rec(), now + 60)
hit = [f for f in fired if f[0] == "fleet_freeze_watchdog_down"]
assert hit, fired
assert "reported by nothing" in hit[0][1], hit
assert "has not grown" in hit[0][1], "the alert must carry the specific cause: %s" % hit[0][1]

# 9. A healthy watchdog clears the counter and fires nothing.
fired.clear(); state.clear()
os.utime(log, (now - 60, now - 60))
lc.evaluate_alerts(rec(), now); lc.evaluate_alerts(rec(), now + 60)
assert not [f for f in fired if f[0] == "fleet_freeze_watchdog_down"], fired

print("ok")
