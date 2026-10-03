#!/usr/bin/env python3
"""LOAD_MON_HERMETIC isolates every READ of this host's real state behind one switch.

The invariant all the alert-count fixtures assume and none could enforce: under
the switch, evaluating the alert rules reads nothing from this host.

Two rules shipped reading real host state and each was isolated by hand, per
knob, after it broke three fixtures. Both knobs existed the second time, so the
mechanism that was missing was never the knob -- it was the requirement to use
it. Measured 2026-10-03 on main tip 514043dd8 with both documented knobs set
exactly as all three fixtures set them, evaluate_alerts still opened this host's
real 133 MB ~/.routines/daemon/routinesd.err.log through a THIRD knob nobody had
enumerated.

Every case here is host-INDEPENDENT on purpose. A guard against "the fixture
depends on real host state" must not itself depend on real host state, or it is
green on a runner and red only on the host that has the files -- which is the
defect it exists to catch.
papercut-load-collector-alert-rules-read-real-host-state-with-no-hermetic-switch-so-each-new-rule-breaks-the-count-fixtures-20261003
"""
import builtins
import importlib.machinery
import importlib.util
import os
import tempfile
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "bin", "last-stack-load-collector")
HOME = os.path.expanduser("~")

# The two module-level HOME-rooted values that are deliberately NOT reads of host
# state. Each states its reason on its own line in the collector. A NEW name
# showing up here is the defect this file exists to catch: add it to host_path(),
# do not add it to this list.
NOT_A_HOST_READ = {"HOME", "DIR", "HERMETIC_ROOT"}


def load(env, tag):
    """Import the collector under an exact environment."""
    saved = dict(os.environ)
    try:
        os.environ.clear()
        os.environ.update(env)
        loader = importlib.machinery.SourceFileLoader("lc_" + tag, SRC)
        spec = importlib.util.spec_from_loader(loader.name, loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
        return mod
    finally:
        os.environ.clear()
        os.environ.update(saved)


def base_env(**extra):
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
           "HOME": HOME,
           "LOAD_MON_DIR": tempfile.mkdtemp(),
           "LOAD_MON_NOTIFY": "0"}
    env.update(extra)
    return env


def healthy():
    return {"node": {"status": {"state": "ok", "vitals": {"up_s": 50000}}},
            "host": {"lastdbd": {"pid": 10, "cpu": 1}, "top": [], "load": [0]}}


def evaluate(mod, rec, now, trace=False):
    """Run the alert rules, optionally recording every real-host path touched."""
    touched = []

    def note(path):
        try:
            path = os.fspath(path)
        except TypeError:
            return
        if isinstance(path, str) and path.startswith(HOME + os.sep):
            touched.append(path.replace(HOME, "~"))

    fired = []
    mod.fire = lambda name, msg, when: fired.append(name)
    state = {}
    mod.load_state = lambda: state
    mod.save_state = lambda st: state.update(st)

    originals = (builtins.open, os.path.exists, os.path.getmtime,
                 os.path.getsize, os.path.isdir, os.listdir, os.stat)
    if trace:
        o_open, o_ex, o_mt, o_sz, o_dir, o_ls, o_st = originals
        builtins.open = lambda f, *a, **k: (note(f), o_open(f, *a, **k))[1]
        os.path.exists = lambda p: (note(p), o_ex(p))[1]
        os.path.getmtime = lambda p: (note(p), o_mt(p))[1]
        os.path.getsize = lambda p: (note(p), o_sz(p))[1]
        os.path.isdir = lambda p: (note(p), o_dir(p))[1]
        os.listdir = lambda p=".": (note(p), o_ls(p))[1]
        os.stat = lambda p, *a, **k: (note(p), o_st(p, *a, **k))[1]
    try:
        # Four passes clear every consecutive-pass threshold, so a rule that
        # needs N agreeing samples still gets the chance to fire.
        for _ in range(4):
            mod.evaluate_alerts(rec, now)
    finally:
        if trace:
            (builtins.open, os.path.exists, os.path.getmtime, os.path.getsize,
             os.path.isdir, os.listdir, os.stat) = originals
    return fired, sorted(set(touched))


now = time.time()

# 1. THE LOAD-BEARING CASE. Under the switch, evaluating every alert rule reads
#    nothing from this host. This is a property over the whole rule set rather
#    than a list of knobs, so a SEVENTH host-state read added later fails here
#    without anyone remembering to extend a list. Asserting ZERO is true on every
#    host, which is what keeps this case host-independent.
mod = load(base_env(LOAD_MON_HERMETIC="1"), "trace")
fired, touched = evaluate(mod, healthy(), now, trace=True)
assert touched == [], "hermetic mode still read this host's real state: %s" % touched

# 2. The invariant all three alert-count fixtures assume: a healthy record under
#    the switch fires nothing, so any count they assert is the count their own
#    record produced.
assert fired == [], "hermetic mode fired on a healthy record: %s" % fired

# 3. An explicit value still wins under the switch, so a fixture can hand ONE
#    rule a crafted plist or log while everything else stays absent. Without
#    this, isolation and per-rule fixtures would be mutually exclusive.
crafted = os.path.join(tempfile.mkdtemp(), "crafted.plist")
open(crafted, "w").write("<plist/>")
mod = load(base_env(LOAD_MON_HERMETIC="1", LOAD_MON_FREEZE_WATCH_PLIST=crafted), "explicit")
assert mod.FW_PLIST == crafted, mod.FW_PLIST
assert mod.FW_DAEMON_LOG.startswith(mod.HERMETIC_ROOT), mod.FW_DAEMON_LOG

# 4. The switch is opt-in: with it off, every default is still the real host
#    path, so production behaviour is unchanged. String comparison only -- this
#    must not require the files to exist.
prod = load(base_env(), "prod")
assert prod.FW_PLIST == os.path.join(
    HOME, "Library/LaunchAgents", prod.FW_LABEL + ".plist"), prod.FW_PLIST
assert prod.FW_DAEMON_LOG == os.path.join(HOME, ".routines/daemon/routinesd.err.log")
assert prod.FRONTIER_DIR == os.path.join(HOME, ".local/state/last-stack/host-track-frontier")
assert not prod.HERMETIC

# 5. The import-time half of case 1, and the one that names the offender. Under
#    the switch no module-level value may still point into the real home except
#    the declared non-reads. Case 1 catches a rule that READS on this record;
#    this catches a knob wired up but only read on some other code path.
mod = load(base_env(LOAD_MON_HERMETIC="1"), "consts")
leaked = sorted(
    name for name, val in vars(mod).items()
    if name.isupper() and name not in NOT_A_HOST_READ
    and isinstance(val, str) and val.startswith(HOME + os.sep))
assert leaked == [], (
    "these host-state defaults bypass host_path(): %s -- route them through it, "
    "do not add them to NOT_A_HOST_READ" % leaked)

print("ok: hermetic host-state switch (5 cases)")
