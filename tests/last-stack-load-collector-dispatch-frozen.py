#!/usr/bin/env python3
"""A scheduler freeze is reported by this agent, not only the watchdog's absence.

`freeze_watch_down` reports that the fleet-freeze watchdog is not running, and
its own alert text ends "(while it is down, a scheduler freeze is reported by
nothing)". That sentence was true. `watchdog_latch_hazard` meanwhile reads
routinesd's own dispatch records every pass and returns None in the one branch
where the freeze is REAL, so the measurement was in hand and the fact was never
published.

Nine dispatch gaps over the 6 h bound are in this host's own routinesd.err.log
between 2026-07-13 and 2026-10-03 (9.3h, 105.7h, 12.3h, 30.9h, 8.9h, 14.3h,
59.8h, 19.0h). Through the 19.0 h one the watchdog was launchctl-disabled from
00:44:45Z, so the fleet was frozen AND unwatched, and the only thing this agent
said was `launchctl enable`.

The load-bearing negatives here are the ones that keep this rule from becoming
noise or from going quiet when it matters most:

  3  a LIVE watchdog owns the verdict, so one freeze is never two notices.
  4  a FRESH dispatch with the watchdog down is not a freeze (the sibling rule's
     own live state for 4670 passes — this must not double it).
  6  the lower-bound arm supplies a WRONG reach (inside the bound), not an
     absent one, so the firing branch is genuinely reached and refused.
  8  ticks are not dispatches, and a tick-only window must still fire via reach.
"""
import importlib.machinery, importlib.util, os, re, stat, tempfile, time

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


def z(age):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now - age)) + ".123Z"


def write_daemon(records):
    """records: list of (age_seconds, kind)."""
    with open(dlog, "w") as f:
        for age, kind in records:
            f.write('{"ts":"%s","kind":"%s","slug":"x"}\n' % (z(age), kind))


def age_of(pattern):
    """The age the RULE will compute, derived from the fixture's own record.

    A literal `"for 80000s"` is a clock flake, not an assertion: `z()` truncates
    to whole seconds while `now` carries a fraction, so the rendered age is
    80000 or 79999 depending on when the suite runs. Two mutation probes went
    RED on exactly that drift instead of on the defect they introduced, which is
    a probe with no verdict. Reading the epoch back from the fixture and using
    the same `now` is exact by construction.
    """
    t = lc.newest_epoch(lc.tail_text(dlog, lc.FW_TAIL_BYTES), pattern) if pattern is lc.FW_DISPATCH_RE \
        else lc.oldest_epoch(lc.tail_text(dlog, lc.FW_TAIL_BYTES), pattern)
    assert t is not None, "age_of fixture sanity"
    return int(now - t)


def beat(age):
    return "%s some-routine ok harness=codex model=m exit=0 dur=1.0s run=/x" % z(age)


def write_bin(two_source=False):
    with open(rbin, "wb") as f:
        f.write(b"x" * 4096)
        if two_source:
            f.write(b"function newestDaemonDispatchAt(dir) {")
        f.write(b"y" * 4096)


write_bin()
with open(hlog, "w") as f:
    f.write(beat(123258) + "\n")

# -------------------------------------------------------------- oldest_epoch
# The arm that keeps the rule alive past the tail window's reach.
write_daemon([(90000, "tick"), (300, "tick")])
txt = lc.tail_text(dlog, lc.FW_TAIL_BYTES)
assert lc.oldest_epoch(txt, lc.FW_ANY_TS_RE) is not None, "reach must parse"
assert abs(now - lc.oldest_epoch(txt, lc.FW_ANY_TS_RE) - 90000) < 2, "oldest, not newest"
assert abs(now - lc.newest_epoch(txt, lc.FW_ANY_TS_RE) - 300) < 2, "newest, not oldest"
assert lc.oldest_epoch("no timestamps here", lc.FW_ANY_TS_RE) is None

# ======================================================== 1. the motivating state
# Frozen AND unwatched: the real 2026-10-02 shape. launchctl-disabled watchdog,
# routinesd's newest dispatch 19 h old.
set_launchctl("disabled")
write_daemon([(90000, "dispatch"), (80000, "complete")])
fw = lc.freeze_watch_down(now)
assert fw, "the sibling must still report the watchdog"
why = lc.dispatch_frozen(now, fw)
assert why, "a freeze with no live watchdog MUST be reported: %r" % why
# 80000, not 90000: the `complete` at 80000s is the newest liveness record, and
# the age is measured from the newest of BOTH kinds, exactly as the watchdog's
# own matcher does. Reading the oldest here would overstate every freeze.
assert "has not dispatched for %ds" % age_of(lc.FW_DISPATCH_RE) in why, why
assert "bound 21600s" in why, "name the bound it was judged against: %s" % why
assert "LOWER BOUND" not in why, "an exact record must not be reported as a bound: %s" % why
assert "launchctl-disabled" in why, "name why nobody else is reporting it: %s" % why
assert "routines freeze-watch" in why, "name the fuller verdict: %s" % why

# 1b. The verdict must survive the render site: headline() cuts at 120 chars and
#     the notice TITLE is what an operator skims.
for passes in (2, 4670, 99999):
    full = "the routine fleet is FROZEN for %d passes: %s" % (passes, why)
    assert "FROZEN" in lc.headline(full), \
        "FROZEN must survive headline() at %d passes: %s" % (passes, lc.headline(full))

# ======================================================= 2. frozen, no watchdog
# An absent plist is not a watchdog fault, so the sibling stays silent — and that
# silence is a statement about the watchdog, never about the fleet. Nothing else
# reports a freeze on such a host, so this rule is the only surface.
os.remove(plist)
assert lc.freeze_watch_down(now) is None, "sibling sanity: an absent plist is not a fault"
why = lc.dispatch_frozen(now, None)
assert why, "a freeze on a host with no watchdog MUST be reported: %r" % why
assert "not installed on this host" in why, why
open(plist, "w").write("<plist/>")

# =================================================== 3. NOT ours: a LIVE watchdog
# It owns this verdict. Two notices for one freeze is how an operator learns to
# ignore both.
set_launchctl("enabled", loaded=True)
open(fwlog, "w").close()
os.utime(fwlog, None)
assert lc.freeze_watch_down(now) is None, "fixture: the watchdog must read as live"
assert lc.dispatch_frozen(now, None) is None, \
    "a live watchdog owns the freeze verdict; this rule must stay quiet"

# ==================================================== 4. NOT a freeze: dispatching
# The sibling's own live state for 4670 passes: watchdog down, scheduler healthy.
# This must not turn that into a fleet-frozen alert.
set_launchctl("disabled")
write_daemon([(90000, "dispatch"), (77, "dispatch"), (60, "complete")])
fw = lc.freeze_watch_down(now)
assert fw, "fixture: the watchdog is still down"
assert lc.dispatch_frozen(now, fw) is None, \
    "a dispatching scheduler is not frozen, whatever the watchdog's state"

# 4b. Exactly AT the bound is not over it. The age is pinned by deriving `now`
#     FROM the record rather than by choosing the record's age: `z()` truncates
#     to whole seconds, so a fixture written as `(BOUND, "dispatch")` is actually
#     BOUND plus whatever fraction `now` carries, and an equality boundary is not
#     expressible that way at all. A test that was green only when time.time()
#     landed near a whole second is a flake, not a boundary.
write_daemon([(BOUND, "dispatch")])
at = lc.newest_epoch(lc.tail_text(dlog, lc.FW_TAIL_BYTES), lc.FW_DISPATCH_RE)
assert at is not None, "fixture sanity"
fw = lc.freeze_watch_down(now)
assert lc.dispatch_frozen(at + BOUND, fw) is None, \
    "age == bound must not fire; the watchdog's own arm is strictly greater"
assert lc.dispatch_frozen(at + BOUND + 1, fw), "one second past the bound must fire"

# ============================================ 5. a `complete` counts as liveness
# The scheduler is demonstrably working when it finishes a run, and the sibling's
# matcher accepts both kinds. Disagreeing here would be two rules reading one log
# two ways.
write_daemon([(90000, "dispatch"), (300, "complete")])
assert lc.dispatch_frozen(now, lc.freeze_watch_down(now)) is None, \
    "a fresh `complete` is dispatch liveness"

# ======================================== 6. the lower-bound arm, reach too SHORT
# A WRONG reach, not an absent one: the window holds records but only reaches
# back 1 h, so "no dispatch in the window" proves nothing past 1 h. The firing
# branch is genuinely reached and must refuse.
write_daemon([(3600, "tick"), (1800, "tick"), (60, "tick")])
assert lc.newest_epoch(lc.tail_text(dlog, lc.FW_TAIL_BYTES), lc.FW_DISPATCH_RE) is None, \
    "fixture: no dispatch record in the window"
assert lc.dispatch_frozen(now, lc.freeze_watch_down(now)) is None, \
    "a window that reaches back less than the bound cannot prove a freeze"

# ======================================== 7. the lower-bound arm, reach LONG enough
# This is the 105.7 h episode: the tail window covers 51.6 h of this log, so from
# hour 52 onward the last dispatch record has scrolled out. Without this arm the
# rule goes quiet exactly as the freeze gets worse.
write_daemon([(400000, "tick"), (200000, "tick"), (60, "tick")])
why = lc.dispatch_frozen(now, lc.freeze_watch_down(now))
assert why, "a window with no dispatch that reaches past the bound MUST fire: %r" % why
assert "LOWER BOUND" in why, "a bound must be declared as a bound, never as a measurement: %s" % why
assert "none in the window" in why, why
assert "has not dispatched for %ds" % age_of(lc.FW_ANY_TS_RE) in why, \
    "reach is the lower bound on age: %s" % why

# ==================================================== 8. ticks are never dispatches
# Through the 59h48m freeze the daemon kept ticking `80 routines in_flight=0`.
# A matcher that accepted ticks would read that log as fresh forever and mask the
# exact outage this rule is about. Case 7's fixture is tick-only and fires; here
# a FRESH tick beside a stale dispatch must not clear the freeze.
write_daemon([(90000, "dispatch"), (10, "tick"), (5, "tick")])
why = lc.dispatch_frozen(now, lc.freeze_watch_down(now))
assert why and "has not dispatched for %ds" % age_of(lc.FW_DISPATCH_RE) in why, \
    "a fresh tick is not a dispatch: %r" % why

# ============================================= 9. CANNOT TELL: no record at all
# An absent, empty or rotated log. The only silence this rule may produce while
# the fleet is unwatched, and it is reported as such rather than hidden.
open(dlog, "w").close()
assert lc.dispatch_frozen(now, lc.freeze_watch_down(now)) is None, \
    "an empty log is not evidence of a freeze"
os.remove(dlog)
assert lc.dispatch_frozen(now, lc.freeze_watch_down(now)) is None, \
    "an absent log is not evidence of a freeze"
with open(dlog, "w") as f:
    f.write("plain text with no json records\n")
assert lc.dispatch_frozen(now, lc.freeze_watch_down(now)) is None, \
    "an unparseable log is not evidence of a freeze"

# ======================================== 10. the notice is scoped to routinesd
# On 2026-10-02 the only alert about a silenced routines watchdog rendered as
# `INFO other systems=lastdbd`, so an operator filtering by system could not find
# it. A new routines-subject rule must not reintroduce that.
systems, kind, sev = lc.ALERT_SCOPE["fleet_dispatch_frozen"]
assert systems == ("routinesd",), systems
assert sev == "warn", "a frozen fleet is refusing work, not crossing a threshold: %s" % sev

# ============================================ 11. every rule is actually WIRED
# The cases above all call `dispatch_frozen` directly, so every one of them stays
# green on a rule that `alerts()` never evaluates and that therefore cannot post
# a notice. A correct detector nothing calls is the defect this whole change is
# about, one layer up, so it gets a structural guard rather than trust.
#
# Both directions, because each is a different silent failure: a name in
# ALERT_SCOPE that nothing fires is a rule that cannot speak, and a fired name
# missing from ALERT_SCOPE renders as `systems=lastdbd` with no severity, which
# is how the 2026-10-02 watchdog alert became unfindable.
#
# Comments are stripped first. The rationale above `dispatch_frozen` names the
# rule in prose, and a guard that matches its own explanation is reading
# something other than what it thinks it is.
src = open(os.path.join(root, "bin", "last-stack-load-collector")).read()
code = "\n".join(l.split("#", 1)[0] for l in src.splitlines())
fired = set(re.findall(r'\(\s*"([a-z_]+)"\s*,\s*st\[', code)) | set(re.findall(r'fire\(\s*"([a-z_]+)"', code))
for name in lc.ALERT_SCOPE:
    assert name in fired, "ALERT_SCOPE has %r but no check fires it: a rule that cannot speak" % name
for name in fired:
    assert name in lc.ALERT_SCOPE, \
        "%r is fired but absent from ALERT_SCOPE, so it renders as systems=lastdbd" % name
assert "fleet_dispatch_frozen" in fired, "fixture sanity: this change's own rule must be wired"

print("ok")
