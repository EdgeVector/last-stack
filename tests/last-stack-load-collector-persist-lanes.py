#!/usr/bin/env python3
"""status_vitals reads persist-lane health; evaluate_alerts fires on unhealthy lanes while status is ok."""
import importlib.machinery, importlib.util, json, os, tempfile

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
os.environ["LOAD_MON_DIR"] = tempfile.mkdtemp()
# Isolate from this host's launchd state: freeze_watch_down reads the real
# ~/Library/LaunchAgents plist, so on a host whose fleet-freeze watchdog is down
# the unrelated fleet_freeze_watchdog_down rule fires and trips `assert not
# fired`. A unit test of another rule must not depend on that. The rule has its
# own coverage in tests/last-stack-load-collector-freeze-watch-liveness.py.
os.environ["LOAD_MON_FREEZE_WATCH_PLIST"] = "/nonexistent/freeze-watch.plist"
loader = importlib.machinery.SourceFileLoader("lc", os.path.join(root, "bin", "last-stack-load-collector"))
spec = importlib.util.spec_from_loader("lc", loader)
lc = importlib.util.module_from_spec(spec)
loader.exec_module(lc)

def body(lanes):
    st = {"status": {"request_ops": {"persist_lanes": lanes}, "resident": {"persist_lane_failures": 7}}}
    return b"HTTP/1.1 200 OK\r\n\r\n" + json.dumps(st).encode()

bad = lc.status_vitals(body([{"unhealthy_lanes": 5, "quarantined": True, "breaker_trips": 2}]))
assert bad["pl_unhealthy"] == 5 and bad["pl_quarantined"] == 1 and bad["pl_breaker"] == 2 and bad["pl_fail"] == 7, bad
good = lc.status_vitals(body([{"unhealthy_lanes": 0, "quarantined": False}]))
assert good["pl_unhealthy"] == 0 and good["pl_quarantined"] == 0, good
assert lc.status_vitals(b"\r\n\r\n{}")["pl_unhealthy"] == 0

fired = []
lc.fire = lambda name, msg, now: fired.append((name, msg))
lc.save_state = lambda st: lc._st.update(st) if hasattr(lc, "_st") else None
state = {}
lc.load_state = lambda: state
def rec(v):
    return {"host": {"load": [1], "top": []}, "node": {"status": {"state": "ok", "vitals": v}}}
now = 10**7
lc.evaluate_alerts(rec(bad), now)
assert not [f for f in fired if f[0] == "lastdb_persist_lanes_unhealthy"], "one pass must not fire"
lc.evaluate_alerts(rec(bad), now + 60)
assert [f for f in fired if f[0] == "lastdb_persist_lanes_unhealthy"], fired
fired.clear(); state.clear()
lc.evaluate_alerts(rec(good), now); lc.evaluate_alerts(rec(good), now + 60)
assert not fired, fired
print("ok")
