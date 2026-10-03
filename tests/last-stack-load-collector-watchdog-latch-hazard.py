#!/usr/bin/env python3
"""A disabled fleet-freeze watchdog is re-enabled only when enabling makes it RIGHT.

`freeze_watch_down` named three causes and three repairs. There is a fourth
state, and its repair is the OPPOSITE of the first one's: the agent is
launchctl-disabled AND the build host-track has installed would compute a false
`dispatch-stale` if it ran. A false `dispatch-stale` and a real one share the
episode key `frozen:dispatch-stale`, and the watchdog's `decideSurfacing`
returns `none` once a key is notified — so enabling it in that state posts one
wrong notice and then surfaces a genuine dispatch freeze with nothing, for good.

Measured on this host 2026-10-03T10:23Z: the installed watchdog printed
`FROZEN dispatch-stale dispatch_age=123258s` while routinesd's own log carried a
`"kind":"dispatch"` record 472 s old, and this agent had prescribed
`launchctl enable` for 3595 consecutive passes.

The cases that MUST keep the plain enable advice are the three "cannot tell"
answers and the real-freeze answer. Inverting a correct repair on a guess is
worse than not inverting it, and a genuine dispatch freeze is exactly when an
operator needs the watchdog back.
"""
import importlib.machinery, importlib.util, os, stat, tempfile, time

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
tmp = tempfile.mkdtemp()
os.environ["LOAD_MON_DIR"] = tmp
LABEL = "com.edgevector.routines-freeze-watch"
plist = os.path.join(tmp, LABEL + ".plist")
fwlog = os.path.join(tmp, "freeze-watch.out.log")
fake = os.path.join(tmp, "launchctl")
dlog = os.path.join(tmp, "routinesd.err.log")
hlog = os.path.join(tmp, "heartbeats.log")
rbin = os.path.join(tmp, "routines")
os.environ["LOAD_MON_FREEZE_WATCH_PLIST"] = plist
os.environ["LOAD_MON_FREEZE_WATCH_LOG"] = fwlog
os.environ["LOAD_MON_LAUNCHCTL"] = fake
os.environ["LOAD_MON_FREEZE_WATCH_INTERVAL_SEC"] = "900"
os.environ["LOAD_MON_ROUTINESD_LOG"] = dlog
os.environ["LOAD_MON_HEARTBEAT_LOG"] = hlog
os.environ["LOAD_MON_ROUTINES_BIN"] = rbin
os.environ["LOAD_MON_FREEZE_WATCH_DISPATCH_BOUND_SEC"] = "21600"

loader = importlib.machinery.SourceFileLoader(
    "lc", os.path.join(root, "bin", "last-stack-load-collector"))
spec = importlib.util.spec_from_loader("lc", loader)
lc = importlib.util.module_from_spec(spec)
loader.exec_module(lc)

BOUND = 21600
now = time.time()
open(plist, "w").write("<plist/>")


def set_launchctl(disabled_state, loaded=True):
    dis = '\t\t"%s" => %s\n' % (LABEL, disabled_state)
    lst = "12762\t-15\tcom.edgevector.load-collector\n" + ("99134\t0\t%s\n" % LABEL if loaded else "")
    with open(fake, "w") as f:
        f.write("#!/bin/sh\ncase \"$1\" in\n")
        f.write("print-disabled) cat <<'EOF'\n%sEOF\n;;\n" % dis)
        f.write("list) cat <<'EOF'\n%sEOF\n;;\nesac\n" % lst)
    os.chmod(fake, os.stat(fake).st_mode | stat.S_IXUSR)


def z(age, frac=True):
    t = time.gmtime(now - age)
    base = time.strftime("%Y-%m-%dT%H:%M:%S", t)
    return base + (".123Z" if frac else "Z")


def write_daemon(records):
    """records: list of (age_seconds, kind)."""
    with open(dlog, "w") as f:
        for age, kind in records:
            f.write('{"ts":"%s","kind":"%s","slug":"x"}\n' % (z(age), kind))


def write_heartbeat(lines):
    with open(hlog, "w") as f:
        for text in lines:
            f.write(text + "\n")


def beat(age):
    return "%s some-routine ok harness=codex model=m exit=0 dur=1.0s run=/x" % z(age)


def write_bin(two_source):
    with open(rbin, "wb") as f:
        f.write(b"x" * 4096)
        if two_source:
            f.write(b"function newestDaemonDispatchAt(dir) {")
        f.write(b"y" * 4096)


# ---------------------------------------------------------------- epoch_z first
# The whole check was silent on real data because epoch_z parsed only
# whole-second timestamps, and BOTH scheduler logs write milliseconds.
assert lc.epoch_z("2026-10-03T10:15:16Z") is not None, "whole seconds must parse"
assert lc.epoch_z("2026-10-03T10:15:16.498Z") is not None, "milliseconds must parse"
assert abs(lc.epoch_z("2026-10-03T10:15:16.498Z")
           - lc.epoch_z("2026-10-03T10:15:16Z") - 0.498) < 1e-6, "fraction must be kept"
assert lc.epoch_z("not a time") is None
assert lc.epoch_z(None) is None

# -------------------------------------------------------------- tail_text seeks
# routinesd.err.log measured 133 MB. A 15-minute agent must not pull it through
# memory; the watchdog's own tailBytes made exactly that mistake.
big = os.path.join(tmp, "big.log")
with open(big, "w") as f:
    f.write("HEAD-MARKER\n" + ("x" * 40000) + "\nTAIL-MARKER\n")
got = lc.tail_text(big, 100)
assert len(got) == 100, len(got)
assert "TAIL-MARKER" in got and "HEAD-MARKER" not in got, got
assert lc.tail_text(os.path.join(tmp, "nope"), 100) == "", "an absent file is not a fault"

# ------------------------------------------------------------- the hazard cases
set_launchctl("disabled")

# 1. HAZARD: routinesd dispatching, heartbeat log blind, single-source build.
#    This is the live 2026-10-03 state.
write_daemon([(90000, "dispatch"), (472, "dispatch"), (460, "complete")])
write_heartbeat([beat(123258)])
write_bin(two_source=False)
why = lc.freeze_watch_down(now)
assert why and "DO NOT ENABLE yet" in why, why
assert "launchctl-disabled" in why, "the cause must still be named: %s" % why
assert "`launchctl enable gui/" not in why, "the harmful prescription must be gone: %s" % why
assert "frozen:dispatch-stale" in why, "name the latch, not just the refusal: %s" % why
assert "82f14a1" in why, "name what has to install first: %s" % why

# 1b. The verdict must survive the render site. headline() cuts at 120 chars and
#     the notice TITLE is what an operator skims; written with the cause first,
#     the title was byte-identical to the harmful version.
for passes in (2, 3595, 99999):
    full = ("the routines fleet-freeze watchdog is not running for %d passes: %s "
            "(while it is down, a scheduler freeze is reported by nothing)" % (passes, why))
    assert "DO NOT ENABLE" in lc.headline(full), \
        "the imperative must survive headline() at %d passes: %s" % (passes, lc.headline(full))

# 2. NOT a hazard: the heartbeat log is FRESH, so the single source is not blind
#    and the installed watchdog computes the right answer.
write_heartbeat([beat(300)])
why = lc.freeze_watch_down(now)
assert why and "`launchctl enable gui/" in why, "a fresh heartbeat must keep the advice: %s" % why
assert "DO NOT ENABLE" not in why, why

# 3. NOT a hazard: the installed build carries the two-source fix, so blindness
#    in the heartbeat log cannot make it wrong. The heartbeat log stays opt-in
#    after the fix, so keying on blindness alone would fire here forever.
write_heartbeat([beat(123258)])
write_bin(two_source=True)
why = lc.freeze_watch_down(now)
assert why and "`launchctl enable gui/" in why, "a fixed build must keep the advice: %s" % why
assert "DO NOT ENABLE" not in why, why

# 4. NOT a hazard: a REAL dispatch freeze. routinesd's newest dispatch is outside
#    the bound, so the watchdog would be right and the operator needs it back.
write_bin(two_source=False)
write_daemon([(90000, "dispatch"), (80000, "complete")])
why = lc.freeze_watch_down(now)
assert why and "`launchctl enable gui/" in why, "a real freeze must keep the advice: %s" % why
assert "DO NOT ENABLE" not in why, why

# 5. `kind":"tick"` must NEVER count as a dispatch. Through the 59h48m freeze the
#    daemon kept ticking and dispatched nothing; a matcher that accepted ticks
#    would read that log as fresh forever and mask the outage this is about.
write_daemon([(90000, "dispatch"), (10, "tick"), (5, "tick")])
why = lc.freeze_watch_down(now)
assert why and "`launchctl enable gui/" in why, "ticks are not dispatches: %s" % why
assert "DO NOT ENABLE" not in why, why
assert lc.newest_epoch(lc.tail_text(dlog), lc.FW_DISPATCH_RE) is not None, "fixture sanity"
assert now - lc.newest_epoch(lc.tail_text(dlog), lc.FW_DISPATCH_RE) > BOUND, \
    "the only in-bound records in this fixture are ticks"

# 6. A heartbeat line that is timestamp-first but carries none of harness=/exit=/
#    dur= is NOT liveness — the installed watchdog rejects it, so this agent must
#    reject it too or it judges against a signal the watchdog cannot see.
write_daemon([(472, "dispatch")])
write_heartbeat([beat(123258), "%s machine-leak-scan finished, 0 findings" % z(60, frac=False)])
why = lc.freeze_watch_down(now)
assert why and "DO NOT ENABLE yet" in why, "a foreign log line must not clear blindness: %s" % why

# 7. CANNOT TELL: the routines binary is unreadable (no host-track install of it).
#    Keep the plain advice — an unreadable binary is not evidence of a defect.
os.rename(rbin, rbin + ".moved")
why = lc.freeze_watch_down(now)
assert why and "`launchctl enable gui/" in why, "an absent binary must keep the advice: %s" % why
assert "DO NOT ENABLE" not in why, why
os.rename(rbin + ".moved", rbin)

# 8. CANNOT TELL: routinesd's log is unreadable. The fleet may really be frozen.
os.rename(dlog, dlog + ".moved")
why = lc.freeze_watch_down(now)
assert why and "`launchctl enable gui/" in why, "an absent daemon log must keep the advice: %s" % why
os.rename(dlog + ".moved", dlog)

# 9. The hazard gates ONLY the disabled arm. A booted-out or silent agent has a
#    different repair and the hazard must not reach either message.
write_heartbeat([beat(123258)])
set_launchctl("enabled", loaded=False)
why = lc.freeze_watch_down(now)
assert why and "not loaded" in why and "DO NOT ENABLE" not in why, why
set_launchctl("enabled", loaded=True)
why = lc.freeze_watch_down(now)
assert why and "never written" in why and "DO NOT ENABLE" not in why, why

# 10. Enabled, loaded, writing: silent, hazard or no hazard. This agent reports
#     that the watchdog is not running; a watchdog that IS running is not its
#     business, even when that watchdog is computing the wrong verdict.
os.utime(fwlog if os.path.exists(fwlog) else open(fwlog, "w").close() or fwlog, None)
assert lc.freeze_watch_down(now) is None, "a live watchdog must be silent here"

# 11. An absent plist is never a fault, even in the hazard state.
os.remove(plist)
set_launchctl("disabled")
assert lc.freeze_watch_down(now) is None, "an absent plist must never alert"
open(plist, "w").write("<plist/>")

print("ok")
