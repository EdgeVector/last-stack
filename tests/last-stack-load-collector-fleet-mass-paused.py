#!/usr/bin/env python3
"""fleet_mass_paused reports a routine registry that is almost entirely paused.

On 2026-10-04 `situations list --json` — the command CLAUDE.md makes every
agent's mandatory first call — returned ONE unrelated p2 while 77 of 81
routines were paused by a five-day-old `go` decision. The largest standing fact
about this host's autonomy had no surface, so each reader reconstructed it from
the `paused` column and three durable records gave three different causes: the
wrong decision date, "there is no resume owner" (there is one, named three days
earlier), and a registry write defect.
papercut-a-95-percent-paused-routine-fleet-is-invisible-to-situations-so-three-records-give-three-causes-20261004

Two things are easy to get wrong here and each has its own case.

THE DENOMINATOR. ~/.routines/registry holds 141 entries and only 81 are
routines. A rule that counts directory entries instead of the `*.toml` glob
reads 76/141 = 55%, which sits under any sane threshold — silent on the exact
state it exists to report. Case 6 plants non-`.toml` files beside the entries.

THE FLOOR. 9 of 9 paused says nothing about a fleet, and a fresh or
half-installed registry must not alert. Cases 4 and 5 sit either side of it.
"""
import importlib.machinery
import importlib.util
import json
import os
import tempfile

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
tmp = tempfile.mkdtemp()
REG = os.path.join(tmp, "registry")
os.environ["LOAD_MON_DIR"] = os.path.join(tmp, "state")
os.environ["LOAD_MON_ROUTINE_REGISTRY_DIR"] = REG
os.environ["LOAD_MON_FRONTIER_DIR"] = os.path.join(tmp, "frontier")
os.environ["LOAD_MON_NOTIFY"] = "0"

loader = importlib.machinery.SourceFileLoader(
    "lc", os.path.join(root, "bin", "last-stack-load-collector"))
lc = importlib.util.module_from_spec(importlib.util.spec_from_loader("lc", loader))
loader.exec_module(lc)

NOW = 1767225600.0  # 2026-01-01T00:00:00Z, a fixed clock


def plant(paused=0, active=0, nostatus=0, junk=0, active_names=None):
    """Rebuild the registry fixture from scratch.

    `nostatus` writes a routine TOML with no `status` key; `junk` writes files
    that are not `*.toml` at all, which is what the real directory is full of.
    """
    if os.path.isdir(REG):
        for f in os.listdir(REG):
            os.unlink(os.path.join(REG, f))
    os.makedirs(REG, exist_ok=True)

    def write(name, body):
        with open(os.path.join(REG, name), "w") as fh:
            fh.write(body)

    names = list(active_names or []) + [
        "auto-active-%03d" % i for i in range(active - len(active_names or []))]
    for n in names:
        write(n + ".toml", 'id = "%s"\nstatus = "active"\ncron = "0 * * * *"\n' % n)
    for i in range(paused):
        write("paused-%03d.toml" % i,
              'id = "paused-%03d"\nstatus = "paused"\ncron = "0 * * * *"\n' % i)
    for i in range(nostatus):
        write("nostatus-%03d.toml" % i, 'id = "nostatus-%03d"\ncron = "0 * * * *"\n' % i)
    for i in range(junk):
        write("junk-%03d.json" % i, "{}\n")


# 1. An absent registry is NOT a fault — a host with no routines installed is a
#    legitimate host, exactly as an absent plist is for the watchdog. Neither is
#    an empty one: the glob matching nothing is the same answer as the directory
#    not being there.
assert not os.path.isdir(REG)
assert lc.fleet_mass_paused() is None, "an absent registry must never alert"
os.makedirs(REG, exist_ok=True)
assert lc.fleet_mass_paused() is None, "an empty registry must never alert"

# 2. THE LIVE SHAPE, 2026-10-04: 77 of 81 paused. The message must name both
#    numbers AND every active id, because "which ones are still running" is the
#    thing an operator cannot get anywhere else and it decides whether the
#    pipeline they depend on is covered.
LIVE_ACTIVE = ["last-stack-fkanban-pickup", "last-stack-fkanban-pickup-w2",
               "last-stack-milestone-driver", "last-stack-disk-reclaim"]
plant(paused=77, active=4, active_names=LIVE_ACTIVE)
why = lc.fleet_mass_paused()
assert why, "the live 77/81 shape did not alert"
assert "77 of 81" in why, why
for name in LIVE_ACTIVE:
    assert name in why, "message drops the active id %r: %s" % (name, why)
# The rule must not read as a verdict on whether the pause is CORRECT. It cannot
# know: a deliberate pause is a brain decision and this agent reads no board and
# no node. Saying so in the message is what stops the next reader resuming a
# fleet an operator deliberately holds.
assert "brain decision" in why, why

# 3. A healthy fleet. 4 of 81 paused is ordinary maintenance.
plant(paused=4, active=77)
assert lc.fleet_mass_paused() is None, "a 4/81 paused fleet alerted"

# 4. THE FLOOR, below. 9 of 9 paused is 100% and must stay silent: a fresh,
#    tiny or half-installed registry is not a mass-paused fleet.
plant(paused=9, active=0)
assert lc.fleet_mass_paused() is None, "a 9/9 registry alerted under the floor"

# 5. THE FLOOR, at it. 10 of 10 is the first total the rule may speak about, so
#    the floor is a bound and not an excuse to stay quiet on a small real fleet.
plant(paused=10, active=0)
why = lc.fleet_mass_paused()
assert why and "10 of 10" in why, "the floor swallowed a 10/10 paused fleet: %r" % why
assert "none" in why, "no active routines must render as 'none': %s" % why

# 6. THE DENOMINATOR. 60 non-`*.toml` files beside the 81 entries, which is the
#    real directory's shape (141 entries, 81 routines). Counting directory
#    entries gives 77/141 = 55% and silence.
plant(paused=77, active=4, junk=60, active_names=LIVE_ACTIVE)
assert len(os.listdir(REG)) == 141, len(os.listdir(REG))
why = lc.fleet_mass_paused()
assert why, "non-.toml files in the registry silenced a 77/81 paused fleet"
assert "77 of 81" in why, "the denominator counted non-routine files: %s" % why

# 7. THE THRESHOLD, both sides, so the comparison direction is pinned. 90 of 100
#    is exactly the default and must fire; 89 must not.
plant(paused=90, active=10)
assert lc.fleet_mass_paused(), "90 of 100 did not fire at a >= 90% threshold"
plant(paused=89, active=11)
assert lc.fleet_mass_paused() is None, "89 of 100 fired at a >= 90% threshold"

# 8. A routine file with NO status line still counts in the denominator. If it
#    did not, a corrupt half of the registry would RAISE the paused ratio while
#    the fleet shrank, which is the wrong direction for a floor to fail in.
plant(paused=72, active=0, nostatus=9)
assert lc.fleet_mass_paused() is None, (
    "9 status-less routines were dropped from the denominator, so 72/81 (88.9%) "
    "read as 72/72 (100%)")
plant(paused=77, active=0, nostatus=4)
assert lc.fleet_mass_paused(), "77 of 81 with 4 status-less entries did not fire"


# --- the rule as the collector runs it -------------------------------------

def frontier(app):
    """A held-install observation in the live frozen shape, for case 10."""
    d = os.environ["LOAD_MON_FRONTIER_DIR"]
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, app + ".json"), "w") as fh:
        json.dump({"app": app, "observer": "refresh", "hold": "pin-behind",
                   "observed_at": lc.iso(NOW - 60),
                   "first_observed_at": lc.iso(NOW - 7200),
                   "running_lastdb_version": "0.23.3-2378-gbe41e547e",
                   "index_newest_version": "0.23.3-2518-ge1177d41a",
                   "index_newest_proved_at": lc.iso(NOW - 1800),
                   "index_newest_oid": "82f14a1ff2a59ad0b20dd2aca2c5ac65cf8f9055",
                   "index_build_match": "mismatch",
                   "running_build_proved_at": lc.iso(NOW - 172800)}, fh)


def evaluate(passes):
    """Drive evaluate_alerts `passes` times and return the alert names fired."""
    fired, state = [], {}
    real_fire, real_load, real_save = lc.fire, lc.load_state, lc.save_state
    lc.fire = lambda name, msg, when: fired.append(name)
    lc.load_state = lambda: state
    lc.save_state = lambda st: state.update(st)
    rec = {"node": {"status": {"state": "ok", "vitals": {"up_s": 50000}}},
           "host": {"lastdbd": {"pid": 10, "cpu": 1}, "top": [], "load": [0]}}
    try:
        for _ in range(passes):
            lc.evaluate_alerts(rec, NOW)
    finally:
        lc.fire, lc.load_state, lc.save_state = real_fire, real_load, real_save
    return fired


# 9. The consecutive-pass counter. A registry caught mid-write must not alert on
#    one sample, so the first pass is silent and the second fires. This is the
#    rule's ONLY temporal bound: a registry file carries no timestamp, so there
#    is nothing honest for the rule itself to compare a clock against.
plant(paused=77, active=4, active_names=LIVE_ACTIVE)
assert lc.FLEET_PAUSED_CONSEC == 2, lc.FLEET_PAUSED_CONSEC
assert "fleet_mass_paused" not in evaluate(1), "fired on a single sample"
assert "fleet_mass_paused" in evaluate(2), "did not fire after two agreeing samples"

# 10. ORDERING, not presence. A paused fleet is UPSTREAM of a frozen prover: on
#     this host the only routine that can prove the running build is itself one
#     of the paused ones, so the pin cannot clear until the posture changes. An
#     operator who reads the pin first acts on the wrong link in the chain, and
#     that is exactly what happened for three consecutive resolver passes. Both
#     rules fire on this fixture, and the posture must come first.
frontier("routines")
fired = evaluate(2)
assert "registry_delivery_frozen" in fired, fired
assert fired.index("fleet_mass_paused") < fired.index("registry_delivery_frozen"), (
    "the frozen prover is reported before the paused fleet that causes it: %s" % fired)

# 11. The notice SCOPE. Without a row in ALERT_SCOPE the alert posts as
#     `systems=lastdbd` at `info` — the wrong system and the wrong severity for
#     a scheduler-posture fact, and silently so. Two sibling guards refuse a
#     rule that ships with no row at all; this pins which row.
assert lc.alert_scope("fleet_mass_paused") == (("routinesd",), "other", "warn"), \
    lc.alert_scope("fleet_mass_paused")

print("ok: fleet_mass_paused (11 cases)")
