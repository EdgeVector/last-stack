#!/usr/bin/env python3
"""evaluate_alerts fires its own check when the memory governor latches purge-failed.

Measured on the primary 2026-10-09: `lastdb status` read `governor_state=purge-failed
governor_state_for=10h host_pressure=high` while `fp_mb_max=1405` -- far under the
13107 MB footprint-high gate -- and the only place `gov` ever reached an alert
message was as a side annotation inside `lastdbd_footprint_high`, gated on that
same footprint threshold. The governor latch was invisible to this instrument for
the entire 10 hours. papercut-lastdb-alert-check-has-no-arm-for-a-sustained-
governor-purge-failed-latch-20261009.

This test pins: (a) the check fires on its OWN consecutive-pass counter, not on
fp_hot; (b) it fires while footprint is low; (c) a one-tick "purge-failed" reading
does not fire (ordinary pressure response, per the fold-side fix this mirrors);
(d) a benign state (e.g. "evicting") never fires it, however long it reads.
"""
import importlib.machinery, importlib.util, json, os, tempfile

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
os.environ["LOAD_MON_DIR"] = tempfile.mkdtemp()
os.environ["LOAD_MON_HERMETIC"] = "1"
loader = importlib.machinery.SourceFileLoader("lc", os.path.join(root, "bin", "last-stack-load-collector"))
spec = importlib.util.spec_from_loader("lc", loader)
lc = importlib.util.module_from_spec(spec)
loader.exec_module(lc)

fired = []
lc.fire = lambda name, msg, now: fired.append((name, msg))
lc.save_state = lambda st: None
state = {}
lc.load_state = lambda: state


def rec(gov, fp_mb=1405):
    return {"host": {"load": [1], "top": []},
            "node": {"status": {"state": "ok", "vitals": {"gov": gov, "fp_mb": fp_mb}}}}


now = 10 ** 7

# (c) one bad pass must not fire
lc.evaluate_alerts(rec("purge-failed"), now)
assert not [f for f in fired if f[0] == "lastdb_governor_purge_failed"], "one pass must not fire"

# (a)+(b) GOV_CONSEC (default 3) consecutive passes fires, with fp_mb far under
# the 13107 MB footprint-high gate -- proves this check does not ride on fp_hot.
lc.evaluate_alerts(rec("purge-failed"), now + 60)
lc.evaluate_alerts(rec("purge-failed"), now + 120)
hits = [f for f in fired if f[0] == "lastdb_governor_purge_failed"]
assert hits, "governor_purge_failed check did not fire after GOV_CONSEC passes: %r" % fired
assert "purge-failed" in hits[0][1] and "independent of footprint" in hits[0][1], hits[0]
assert not [f for f in fired if f[0] == "lastdbd_footprint_high"], \
    "footprint check must not fire at fp_mb=1405"

# (d) a benign latched state never fires this arm, however long it holds
fired.clear(); state.clear()
for i in range(10):
    lc.evaluate_alerts(rec("evicting"), now + i * 60)
assert not [f for f in fired if f[0] == "lastdb_governor_purge_failed"], \
    "a benign governor state must never fire the purge-failed arm"

# clearing (a successful purge) resets the counter: exercise the reset, then
# confirm a fresh latch still needs its own GOV_CONSEC passes, not a leftover one
fired.clear(); state.clear()
lc.evaluate_alerts(rec("purge-failed"), now)
lc.evaluate_alerts(rec("purge-failed"), now + 60)
lc.evaluate_alerts(rec("ok"), now + 120)
lc.evaluate_alerts(rec("purge-failed"), now + 180)
assert not [f for f in fired if f[0] == "lastdb_governor_purge_failed"], \
    "a cleared latch must not carry its count into the next one"

print("ok last-stack-load-collector-governor-purge-failed")
