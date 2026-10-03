#!/usr/bin/env python3
"""frontier_frozen reports a registry pin that is holding installs, and stays quiet otherwise.

`host-track` has computed `pin_behind_oid` since 2026-09-26 and four more
pin-lag fields since 2026-10-03, and until this rule nothing on the host read
any of them: measured, 54 occurrences in bin/host-track and zero elsewhere.
From 2026-10-01T22:10Z `brain` and `routines` were undeliverable for 34 h —
EdgeVector/routines PR 11, the fix for the only out-of-fleet fleet-freeze
watchdog, was among the commits held — and no notice, situation or live
classifier said so. `last-stack-why-stopped` gained a class for it that
morning, and every consumer of that classifier is among the 78 paused routines.
This agent is a LaunchAgent and is running, which is why the rule lives here.
papercut-host-track-pin-lag-fields-are-rendered-to-nobody-no-classifier-or-notice-reads-them-20261003

The predicate is deliberately NOT "the frontier is old". After a LastDB version
change every pinned app legitimately holds until the prover writes a row for the
new build, which can be most of a day; alerting through that window every half
hour is noise an operator learns to ignore. The discriminator is that the prover
produced a row for a DIFFERENT build WHILE this app was already held — proof it
is alive and will never serve this host. That needs no age threshold and cannot
disagree with Class H, which fires on age because it had no second side.
"""
import importlib.machinery, importlib.util, json, os, tempfile, time

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
tmp = tempfile.mkdtemp()
os.environ["LOAD_MON_DIR"] = os.path.join(tmp, "state")
os.environ["LOAD_MON_FRONTIER_DIR"] = os.path.join(tmp, "frontier")
FDIR = os.environ["LOAD_MON_FRONTIER_DIR"]

loader = importlib.machinery.SourceFileLoader(
    "lc", os.path.join(root, "bin", "last-stack-load-collector"))
lc = importlib.util.module_from_spec(importlib.util.spec_from_loader("lc", loader))
loader.exec_module(lc)

NOW = 1767225600.0  # 2026-01-01T00:00:00Z, a fixed clock


def z(offset):
    return lc.iso(NOW + offset)


def write(app, **over):
    o = {"app": app, "observer": "refresh", "hold": "pin-behind",
         "observed_at": z(-60), "first_observed_at": z(-7200),
         "running_lastdb_version": "0.23.3-2378-gbe41e547e",
         "index_newest_version": "0.23.3-2518-ge1177d41a",
         "index_newest_proved_at": z(-1800),
         "index_newest_oid": "82f14a1ff2a59ad0b20dd2aca2c5ac65cf8f9055",
         "index_build_match": "mismatch"}
    o.update(over)
    os.makedirs(FDIR, exist_ok=True)
    with open(os.path.join(FDIR, app + ".json"), "w") as f:
        json.dump(o, f)


def clear():
    for f in os.listdir(FDIR) if os.path.isdir(FDIR) else []:
        os.unlink(os.path.join(FDIR, f))


# 1. No cache directory at all. Nothing is held, or no host-track that writes
#    observations is installed yet. NEVER a fault: an alert here would fire
#    forever on every host that has no registry pin.
assert not os.path.isdir(FDIR)
assert lc.frontier_frozen(NOW) is None, "an absent cache must never alert"

os.makedirs(FDIR, exist_ok=True)
assert lc.frontier_frozen(NOW) is None, "an empty cache must never alert"

# 2. The live shape, 2026-10-03: held, mismatch, and the prover produced a row
#    for another build after the hold began. The message must carry every fact
#    an operator needs to act without opening a second tool: which apps, the
#    running build, the frontier's build, when it was proved, the oid they are
#    held behind, since when, and how old the observation itself is.
write("routines")
why = lc.frontier_frozen(NOW)
assert why, "the live frozen shape did not alert"
for needle in ("routines", "0.23.3-2378-gbe41e547e", "0.23.3-2518-ge1177d41a",
               "82f14a1ff2a5", z(-1800), z(-7200), "observed by host-track 60s ago"):
    assert needle in why, "message drops %r: %s" % (needle, why)
# The remedy must be the one that can work. "Wait" and "resume the prover" are
# both wrong here and both were prescribed by earlier readers of these fields.
assert "prove the running build" in why, why
assert "never serve this host" in why, why

# 3. The frontier is on the RUNNING build. Then the age decides, which is Class
#    H's question, not this one. Silence, or the two detectors disagree.
clear()
write("routines", index_build_match="match",
      index_newest_version="0.23.3-2378-gbe41e547e")
assert lc.frontier_frozen(NOW) is None, "a frontier on the running build must not alert"

# 4. The cause could not be read. `host-track` still records the hold, with
#    `unread`; "I did not look" must never render as a measured freeze.
clear()
write("routines", index_build_match="unread", index_newest_version=None)
assert lc.frontier_frozen(NOW) is None, "an unread cause rendered as a measured freeze"

# 5. The index was read and holds no row on any build. A different claim again,
#    and one this rule has nothing to say about.
clear()
write("routines", index_build_match="no-rows")
assert lc.frontier_frozen(NOW) is None, "no-rows rendered as a build mismatch"

# 6. The benign post-upgrade wait: mismatch, but the newest row predates the
#    hold, so nothing has been proved for another build since this app was
#    held. This is the case an age threshold gets wrong, and the whole reason
#    the predicate compares two timestamps instead of one against a bound.
clear()
write("routines", index_newest_proved_at=z(-9000))  # before first_observed_at
assert lc.frontier_frozen(NOW) is None, \
    "a row proved BEFORE the hold began counted as the prover working past us"

# 7. A stale observation is not evidence about the present. Past the bound the
#    writer is not running, and this rule must not keep an old verdict alive.
clear()
write("routines", observed_at=z(-7000))
assert lc.frontier_frozen(NOW) is None, "a stale observation still alerted"
# One tick inside the bound still alerts: the default is three ticks of the
# 1200 s host-track-refresh agent, so a single missed tick must not silence it.
clear()
write("routines", observed_at=z(-1300))
assert lc.frontier_frozen(NOW), "a one-tick-old observation was treated as stale"

# 8. Per-app, not per-directory: one wedged or healthy file must not silence a
#    held sibling, and the alert names every held app.
clear()
write("routines")
write("brain", index_newest_oid="b703057a261576cca60e43da35187a133619b014")
write("situations", index_build_match="match")
write("search", observed_at=z(-9999))
why = lc.frontier_frozen(NOW)
assert why and "brain,routines" in why, "the alert did not name every held app: %s" % why
assert "situations" not in why and "search" not in why, \
    "an app that is not frozen was named: %s" % why

# 9. Garbage in the cache is skipped, not fatal: this runs inside a 30 s sampler
#    whose whole contract is that one bad section cannot cost the pass.
clear()
with open(os.path.join(FDIR, "broken.json"), "w") as f:
    f.write("{not json")
with open(os.path.join(FDIR, "list.json"), "w") as f:
    f.write("[1,2,3]")
write("routines")
why = lc.frontier_frozen(NOW)
assert why and "routines" in why and "broken" not in why, why

# 10. The hold is reported through the alert table, with the system and severity
#     an operator filters on. `other`/`lastdbd`/no-severity was the shape that
#     made a silenced routines watchdog unfindable on the notices timeline.
systems, kind, sev = lc.alert_scope("registry_delivery_frozen")
assert systems == ("host-track",), systems
assert sev == "warn", "a refused install is a refusal, not a threshold crossing: %s" % sev
argv = lc.notice_argv("/bin/situations", "registry_delivery_frozen", why)
assert "--system" in argv and "host-track" in argv, argv
assert argv[argv.index("--severity-hint") + 1] == "warn", argv
assert argv[-1] == why, "the summary must carry the untruncated message"

# 11. `guarded` must RETURN a non-dict fallback, not raise through its own except
#     block. Two call sites pass None, including the one wrapping this rule, and
#     `dict(None)` raised TypeError out of the guard — killing evaluate_alerts
#     and dropping EVERY alert for that pass. Probed against the installed
#     binary 2026-10-03 before the fix.
def boom():
    raise ZeroDivisionError("probe")


assert lc.guarded(boom, None) is None, "guarded(fn, None) must return None, not raise"
assert lc.guarded(boom, {"a": 1})["error"].startswith("ZeroDivisionError"), \
    "guarded lost the dict-fallback error annotation"

print("PASS last-stack-load-collector-frontier-frozen")
