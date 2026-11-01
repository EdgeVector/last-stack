#!/usr/bin/env python3
"""Validate one owned native cloud recovery status sample with exact integers.

Default (strict gate): print "ok <published> <age>", or a fixed refusal and exit 1.
--report: print which checks fail. A malformed or nonfresh sample still exits 1.
Bounded waiver (all four --waiver/--candidate options together): a refused sample
passes only when a Tom-approved decision record names this candidate's lastdbd
sha256, is under 24 hours old, and the unpublished window is known and within the
waiver limit. The window is the time between the local durable frontier and the
published frontier (mutation_log_lag). It is the span of writes that the cloud
backup does not hold. mutation_log_recovery_point_age_secs is not that span.
Print "waived <published> <window secs> <failed,checks>". A refused waiver prints
"waiver refused: <fixed reason>" and exits 1.
Every mode first requires an exact native sampled_at at most 300 seconds old.
--status-sample-only checks only that protected snapshot and its sample age.

A strict refusal prints "refused failed=<check,names>". A sample that cannot be
decoded prints "refused".

Format 7 V2 route (--v2-status): a home without the retired status.sync object
uses status.durability and the protected output of
`lastdb --data-dir <home> cloud backup-v2 status --json`. The recovery point is
current when the mutation log head equals the last backed-up frontiers, the
accepted backup is recorded, nothing is degraded, paused, blocked or retained,
and the V2 sample is at most --max-age-secs old. Print
"ok-v2 <main>/<cas> <age> <stream id> <ordinal>". The V2 route takes no waiver.
A status without sync and without --v2-status refuses with sync_object_absent.
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time

CAP = 4 * 1024 * 1024
DECISION_CAP = 256 * 1024
U64_MAX = 18446744073709551615
STATUS_SAMPLE_MAX_AGE_SECS = 300
WAIVER_PROGRAM = "lastdb-safe-upgrade"
WAIVER_GATE = "stale-recovery-point-cutover"
WAIVER_APPROVER = "Tom"
WAIVER_DECISION_MAX_AGE = timedelta(hours=24)
WAIVER_CLOCK_SKEW = timedelta(minutes=5)
SLUG = re.compile(r"decision-[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9][a-z0-9-]{0,120}")
CREATED = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?Z")


class Refusal(Exception):
    """A bounded waiver refusal. The message is a fixed string, never file text."""


class StatusSampleRefusal(Exception):
    """A fixed native snapshot freshness verdict; no captured values are printed."""


class CheckRefusal(Exception):
    """Named failed checks. The names are fixed strings, never file text."""


def require(value):
    if not value:
        raise ValueError("cloud recovery status refused")


def metadata(info):
    return (info.st_uid, info.st_mode, info.st_dev, info.st_ino, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result)
        result[key] = value
    return result


def integer(token):
    require(len(token) <= 21)
    return int(token)


def floating(token):
    require(len(token) <= 128)
    value = float(token)
    require(math.isfinite(value))
    return value


def read_status(path):
    require(path.is_absolute())
    parent = path.parent.lstat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid())
    require(stat.S_IMODE(parent.st_mode) == 0o700)
    physical = path.parent.resolve(strict=True)
    parent_fd = os.open(physical, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    fd = None
    try:
        require(metadata(os.fstat(parent_fd)) == metadata(parent))
        before = path.lstat()
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid())
        require(stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1)
        require(0 < before.st_size <= CAP)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        require(metadata(os.fstat(fd)) == metadata(before))
        raw = bytearray()
        while len(raw) <= CAP:
            block = os.read(fd, min(65536, CAP + 1 - len(raw)))
            if not block:
                break
            raw.extend(block)
        require(len(raw) == before.st_size)
        require(metadata(os.fstat(fd)) == metadata(before))
        require(metadata(path.lstat()) == metadata(before))
        require(path.parent.resolve(strict=True) == physical)
        require(metadata(path.parent.lstat()) == metadata(parent))
        require(metadata(os.fstat(parent_fd)) == metadata(parent))
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent_fd)
    return json.loads(bytes(raw).decode("utf-8", errors="strict"), object_pairs_hook=pairs,
                      parse_int=integer, parse_float=floating,
                      parse_constant=lambda _value: require(False))


def unsigned(value):
    require(type(value) is int and 0 <= value <= U64_MAX)
    return value


def load_status(path):
    """Return the whole response; its status object has a fresh sample time."""
    value = read_status(path)
    require(type(value) is dict and value.get("ok") is True)
    require(type(value.get("status")) is dict)
    status = value["status"]
    if "sampled_at" not in status:
        raise StatusSampleRefusal("status-sample-missing")
    sampled_at = status["sampled_at"]
    if type(sampled_at) is not int or not 0 < sampled_at <= U64_MAX:
        raise StatusSampleRefusal("status-sample-invalid")
    now_ns = time.time_ns()
    sampled_at_ns = sampled_at * 1_000_000_000
    if sampled_at_ns > now_ns:
        raise StatusSampleRefusal("status-sample-future")
    if now_ns - sampled_at_ns > STATUS_SAMPLE_MAX_AGE_SECS * 1_000_000_000:
        raise StatusSampleRefusal("status-sample-stale")
    return value


def frontier_pair(value):
    require(type(value) is dict and set(value) == {"main", "cas"})
    return unsigned(value["main"]), unsigned(value["cas"])


def v2_failed_checks(response, v2, v2_mtime_ns, max_age):
    """Return (failed check names, head frontiers, backup age, stream id, ordinal).

    Every check is lenient: a missing or malformed value is a failed check.
    """
    failed = []
    status = response["status"]

    def check(name, test):
        try:
            passed = test() is True
        except (ValueError, TypeError, KeyError, AttributeError):
            passed = False
        if not passed:
            failed.append(name)

    def lenient(read):
        try:
            return read()
        except (ValueError, TypeError, KeyError, AttributeError):
            return None

    durability = status.get("durability")
    durability = durability if type(durability) is dict else {}
    v2 = v2 if type(v2) is dict else {}
    automatic = v2.get("automatic_backup")
    automatic = automatic if type(automatic) is dict else {}
    log = v2.get("mutation_log")
    log = log if type(log) is dict else {}
    accepted = v2.get("last_accepted_backup")
    accepted = accepted if type(accepted) is dict else {}
    now_ns = time.time_ns()

    check("durability_observed", lambda: durability["observed"] is True)
    check("durability_automatic_enabled", lambda: durability["automatic_enabled"] is True)
    check("durability_degraded", lambda: "degraded" in durability and durability["degraded"] is None)
    check("durability_accepted_backup", lambda: durability["accepted_backup_recorded"] is True)
    check("v2_sample_age", lambda: 0 <= now_ns - v2_mtime_ns <= max_age * 1_000_000_000)
    check("v2_ok", lambda: v2["ok"] is True)
    check("v2_user_hash", lambda: type(v2["user_hash"]) is str
          and re.fullmatch(r"[0-9a-f]{32}", v2["user_hash"]) is not None
          and v2["user_hash"] == response.get("user_hash"))
    check("v2_enabled", lambda: v2["enabled"] is True)
    check("v2_automatic_enabled", lambda: v2["automatic_backup_enabled"] is True
          and automatic["enabled"] is True)
    check("v2_paused", lambda: "paused" in automatic and automatic["paused"] is None)
    check("v2_blocked", lambda: "blocked_reason" in v2 and v2["blocked_reason"] is None)
    stream = lenient(lambda: accepted["begin"]["job"]["stream"]["stream_id"])
    stream = stream if type(stream) is str and re.fullmatch(r"[0-9a-f-]{36}", stream) else None
    ordinal = accepted.get("ordinal")
    ordinal = ordinal if type(ordinal) is str and re.fullmatch(r"[0-9]{1,20}", ordinal) else None
    check("v2_accepted_backup", lambda: stream is not None and ordinal is not None)
    check("v2_mutation_log_enabled", lambda: log["enabled"] is True)
    check("v2_log_gap", lambda: "gap" in log and log["gap"] is None)
    check("v2_snapshot_required", lambda: log["snapshot_required"] is False)
    check("v2_retained_bytes", lambda: unsigned(log["retained_bytes"]) == 0
          and unsigned(v2["retained_source_bytes"]) == 0)
    check("v2_acknowledged_head", lambda: unsigned(log["acknowledged_through"])
          == unsigned(log["head"]["sequence"]))
    head = lenient(lambda: frontier_pair(log["head"]["frontiers"]))
    backed = lenient(lambda: frontier_pair(automatic["last_backed_up_frontiers"]))
    check("v2_head_backed", lambda: head is not None and head == backed)
    completed = lenient(lambda: unsigned(automatic["last_completed_at"]))
    age = None
    if completed is not None and completed * 1_000_000_000 <= now_ns:
        age = (now_ns - completed * 1_000_000_000) // 1_000_000_000
    return failed, head, age, stream, ordinal


def number(sync, key, lenient):
    """An exact unsigned integer. A lenient read turns a bad value into None."""
    try:
        return unsigned(sync.get(key))
    except ValueError:
        if lenient:
            return None
        raise


def failed_checks(sync, max_age, lenient):
    """Return (failed check names, published frontier, recovery point age, window).

    The window is the span in seconds between the newest local frontier and the
    published frontier, or None when a frontier is unknown.

    The strict gate calls this with lenient=False: a missing or malformed value
    raises, as before. Report and waiver modes call it with lenient=True.
    """
    failed = []

    def check(name, condition):
        if not condition:
            failed.append(name)

    check("sync_enabled", sync.get("enabled") is True)
    check("sync_state", sync.get("state") in ("Idle", "Dirty", "Syncing"))
    check("sync_degraded", sync.get("sync_degraded") is False)
    check("consecutive_sync_failures", number(sync, "consecutive_sync_failures", lenient) == 0)
    check("last_error", "last_error" in sync and sync["last_error"] is None)
    check("replay_blocker", "replay_blocker" in sync and sync["replay_blocker"] is None)
    check("mutation_log_active", sync.get("mutation_log_active") is True)
    check("mutation_log_lag_degraded", sync.get("mutation_log_lag_degraded") is False)
    frontier = number(sync, "mutation_log_frontier_f", lenient)
    durable = number(sync, "mutation_log_last_durable_frontier", lenient)
    published = number(sync, "mutation_log_published_through", lenient)
    check("published_covers_frontier",
          None not in (frontier, durable, published)
          and published >= frontier and published >= durable)
    for key in ("upload_queue_count", "pending_count", "durable_outbox_count"):
        check(key, number(sync, key, lenient) == 0)
    age = number(sync, "mutation_log_recovery_point_age_secs", lenient)
    check("recovery_point_age", age is not None and age <= max_age)
    window = None
    if None not in (frontier, durable, published):
        window = max(0, max(frontier, durable) - published) // 1_000_000_000
    return failed, published, age, window


def read_decision(path):
    require(path.is_absolute())
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid())
    require(stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1)
    require(0 < before.st_size <= DECISION_CAP)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        require(metadata(os.fstat(fd)) == metadata(before))
        raw = bytearray()
        while len(raw) <= DECISION_CAP:
            block = os.read(fd, DECISION_CAP + 1 - len(raw))
            if not block:
                break
            raw.extend(block)
    finally:
        os.close(fd)
    require(len(raw) == before.st_size)
    return json.loads(bytes(raw).decode("utf-8", errors="strict"), object_pairs_hook=pairs,
                      parse_constant=lambda _value: require(False))


def refuse_unless(condition, reason):
    if not condition:
        raise Refusal(reason)


def check_waiver(decision_path, slug, candidate_sha256, published, window, waiver_max_window):
    """Raise Refusal unless every bound of the waiver holds."""
    require(SLUG.fullmatch(slug) is not None)
    require(re.fullmatch(r"[0-9a-f]{64}", candidate_sha256) is not None)
    refuse_unless(published is not None and published > 0,
                  "no cloud recovery point has been published")
    refuse_unless(window is not None and window <= waiver_max_window,
                  "the unpublished window is unknown or beyond the waiver limit")
    doc = read_decision(decision_path)
    refuse_unless(type(doc) is dict and doc.get("slug") == slug
                  and doc.get("type") == "decision" and doc.get("status") == "go",
                  "the record is not an approved decision with that slug")
    extra = doc.get("extra_fields")
    refuse_unless(type(extra) is dict and extra.get("decided_by") == WAIVER_APPROVER
                  and extra.get("program") == WAIVER_PROGRAM
                  and extra.get("gate_slug") == WAIVER_GATE,
                  "the decision is not approved by Tom for this gate")
    created = CREATED.fullmatch(doc.get("created_at") if type(doc.get("created_at")) is str else "")
    refuse_unless(created is not None, "the decision has no creation time")
    made = datetime(*[int(part) for part in created.groups()], tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    refuse_unless(-WAIVER_CLOCK_SKEW <= now - made <= WAIVER_DECISION_MAX_AGE,
                  "the decision is older than 24 hours")
    body = doc.get("body")
    refuse_unless(type(body) is str and candidate_sha256 in body.lower(),
                  "the decision does not name this candidate's lastdbd sha256")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--status", required=True, type=Path)
    parser.add_argument("--v2-status", type=Path)
    parser.add_argument("--max-age-secs", required=True)
    parser.add_argument("--report", action="store_true")
    parser.add_argument("--status-sample-only", action="store_true")
    parser.add_argument("--waiver-decision", type=Path)
    parser.add_argument("--waiver-slug")
    parser.add_argument("--candidate-sha256")
    parser.add_argument("--waiver-max-window-secs")
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9]+", args.max_age_secs) is not None)
    require(len(args.max_age_secs) <= 20)
    max_age = unsigned(int(args.max_age_secs))
    # Freshness precedes report and waiver selection, so no backup waiver can
    # authorize stale cached sync flags.
    response = load_status(args.status)
    status = response["status"]
    waiver = (args.waiver_decision, args.waiver_slug, args.candidate_sha256,
              args.waiver_max_window_secs)
    if args.status_sample_only:
        require(not args.report and not any(waiver) and args.v2_status is None)
        print("status-sample-fresh")
        return
    if "sync" not in status:
        if any(waiver):
            raise Refusal("the status has no legacy sync object; the V2 route takes no waiver")
        if args.v2_status is None:
            if args.report:
                print("report failed=sync_object_absent published=- age=- window=- state=?")
                return
            raise CheckRefusal(["sync_object_absent"])
        v2 = read_status(args.v2_status)
        v2_mtime_ns = args.v2_status.lstat().st_mtime_ns
        failed, head, age, stream, ordinal = v2_failed_checks(response, v2, v2_mtime_ns, max_age)
        if args.report:
            phase = v2.get("phase") if type(v2) is dict else None
            phase = phase if type(phase) is str and re.fullmatch(r"[a-z_]{1,32}", phase) else "?"
            print("report failed=%s published=%s age=%s window=- state=%s" % (
                ",".join(failed) or "none",
                "-" if head is None else "%d/%d" % head,
                "-" if age is None else age, phase))
            return
        if failed:
            raise CheckRefusal(failed)
        print("ok-v2 %d/%d %s %s %s" % (head[0], head[1], "-" if age is None else age,
                                        stream, ordinal))
        return
    require(args.v2_status is None)
    sync = status["sync"]
    require(type(sync) is dict)
    if not args.report and not any(waiver):
        failed, published, age, _window = failed_checks(sync, max_age, lenient=True)
        if failed:
            raise CheckRefusal(failed)
        print("ok %d %d" % (published, age))
        return
    failed, published, age, window = failed_checks(sync, max_age, lenient=True)
    if args.report:
        require(not any(waiver))
        state = sync.get("state")
        state = state if type(state) is str and re.fullmatch(r"[A-Za-z]{1,16}", state) else "?"
        print("report failed=%s published=%s age=%s window=%s state=%s" % (
            ",".join(failed) or "none",
            "-" if published is None else published,
            "-" if age is None else age,
            "-" if window is None else window, state))
        return
    require(all(waiver))
    if not failed:
        print("ok %d %d" % (published, age))
        return
    require(re.fullmatch(r"[0-9]{1,20}", args.waiver_max_window_secs) is not None)
    check_waiver(args.waiver_decision, args.waiver_slug, args.candidate_sha256,
                 published, window, unsigned(int(args.waiver_max_window_secs)))
    print("waived %d %d %s" % (published, window, ",".join(failed)))


if __name__ == "__main__":
    try:
        main()
    except StatusSampleRefusal as refusal:
        print(refusal)
        raise SystemExit(1)
    except CheckRefusal as refusal:
        print("refused failed=%s" % ",".join(refusal.args[0]))
        raise SystemExit(1)
    except Refusal as refusal:
        print("waiver refused: %s" % refusal)
        raise SystemExit(1)
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        print("refused")
        raise SystemExit(1)
