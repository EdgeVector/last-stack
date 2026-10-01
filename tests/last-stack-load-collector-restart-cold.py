#!/usr/bin/env python3
"""cold_group_max reads keep_small group sizes; evaluate_alerts fires on a pid change and a near-cap group."""
import importlib.machinery, importlib.util, os, sys, tempfile

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
loader = importlib.machinery.SourceFileLoader("lc", os.path.join(root, "bin", "last-stack-load-collector"))
spec = importlib.util.spec_from_loader("lc", loader)
lc = importlib.util.module_from_spec(spec)
loader.exec_module(lc)

d = tempfile.mkdtemp()
assert lc.cold_group_max(d) is None
g = os.path.join(d, "keep_small", "0", "g", "025")
os.makedirs(g)
open(os.path.join(g, "1.seg"), "wb").write(b"x" * 1000)
open(os.path.join(g, "2.seg"), "wb").write(b"x" * 500)
assert lc.cold_group_max(d) == {"group": "025", "bytes": 1500}, lc.cold_group_max(d)

lc.DIR = tempfile.mkdtemp()
fired = []
lc.fire = lambda name, msg, now: fired.append((name, msg))
state = {}
lc.load_state = lambda: state
lc.save_state = lambda st: state.update(st)

def rec(pid, cold):
    return {"node": {"status": {"state": "ok", "vitals": {"up_s": 5}}},
            "host": {"lastdbd": {"pid": pid, "cpu": 1}, "top": [], "load": [0], "cold_group": cold}}

lc.evaluate_alerts(rec(10, None), 1000)
assert not fired
lc.evaluate_alerts(rec(11, None), 1060)
assert [n for n, _ in fired] == ["lastdbd_restarted"] and "10 -> 11" in fired[0][1], fired
fired.clear()
big = {"group": "025", "bytes": lc.COLD_CAP_BYTES}
lc.evaluate_alerts(rec(11, big), 5000)
assert not fired  # needs 2 passes
lc.evaluate_alerts(rec(11, big), 5060)
assert [n for n, _ in fired] == ["lastdb_cold_group_near_cap"], fired
print("ok")
