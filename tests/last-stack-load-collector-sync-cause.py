#!/usr/bin/env python3
"""sync_cause names why sync lags: recent cloud error, recovery-point age, backlog."""
import importlib.machinery, importlib.util, os, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
loader = importlib.machinery.SourceFileLoader("lc", os.path.join(root, "bin", "last-stack-load-collector"))
spec = importlib.util.spec_from_loader("lc", loader)
lc = importlib.util.module_from_spec(spec)
loader.exec_module(lc)

now = 1000000
v = {"sync_err": "auth Lambda HTTP 503", "sync_err_at": now - 60, "rp_age_s": 358, "dl_deferred": 23218}
out = lc.sync_cause(v, now)
assert "last error 60s ago: auth Lambda HTTP 503" in out, out
assert "recovery point 358s old" in out and "23218 download entries deferred" in out, out
stale = dict(v, sync_err_at=now - 5000)
assert "last error" not in lc.sync_cause(stale, now)
assert lc.sync_cause({}, now) == ""
print("ok")
