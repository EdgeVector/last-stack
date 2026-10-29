"""Read-only Run V2 health without pack-maintenance assumptions."""

from concurrent.futures import ThreadPoolExecutor
import http.client
import time

from native_upgrade_common import NotReady, call, require

COUNTERS = ("generation", "frontier", "accepted_batches", "accepted_sequence", "completed_sequence")
FAILURES = ("maintenance_failures", "reclaim_failures", "persist_lane_failures", "deferred_persist_failed")
ERRORS = ("maintenance_last_error", "reclaim_last_error")


def zero_failures(value):
    require(isinstance(value, dict), "Run V2 health object is absent")
    for name in FAILURES:
        if name in value:
            require(type(value[name]) is int and value[name] == 0,
                    "Run V2 failure gauge is invalid or nonzero: " + name)
    for name in ERRORS:
        if name in value:
            require(value[name] is None, "Run V2 current error is set: " + name)


def health(sock, version, pid, *, automatic=False):
    require(type(automatic) is bool, "Run V2 backup policy is invalid")
    require(type(pid) is int and pid > 0, "Run V2 supervised PID is absent")
    routes = ("/health", "/api/version", "/api/status", "/api/db/native-status")
    with ThreadPoolExecutor(max_workers=4) as workers:
        responses = list(workers.map(lambda route: call(sock, route), routes))
    value, build, response, disk = responses
    require(value.get("status") == "ok" and isinstance(value.get("instance_id"), str)
            and value["instance_id"].startswith(str(pid) + "-"),
            "Run V2 health and supervised process differ")
    require(build.get("build") == version, "Run V2 live version differs from the bound pair")
    status = response["status"]
    sampled = status.get("sampled_at")
    require(type(sampled) is int and 0 <= time.time() - sampled <= 300,
            "Run V2 status sample is absent, future, or stale")
    sync = status.get("sync")  # absent on nodes that no longer report the sync object
    if sync is not None:
        require(sync.get("enabled") is False and sync.get("local_writable") is True,
                "Run V2 must stay writable with Cloud Off")
    durability = status.get("durability", {})
    require(durability.get("observed") is True
            and durability.get("automatic_enabled") is automatic
            and (type(durability.get("running")) is bool if automatic
                 else durability.get("running") is False),
            "Run V2 requires the exact observed backup policy")
    if automatic:
        require(durability.get("degraded") is None,
                "The automatic backup reports degraded durability")
    resident = status.get("resident", {})
    require(all(type(resident.get(name)) is int and resident[name] == 0
                for name in ("persist_lane_failures", "deferred_persist_failed")),
            "Run V2 persist failure gauges are absent or nonzero")
    native = disk["native_disk"]
    require(native.get("writer_failed") is False, "Run V2 native writer failed")
    require(all(type(native.get(name)) is int and 0 <= native[name] <= 2**64 - 1 for name in COUNTERS)
            and native["completed_sequence"] <= native["accepted_sequence"],
            "Run V2 native boundary counters are absent or invalid")
    zero_failures(resident)
    zero_failures(native)
    zero_failures(native.get("parts", {}))
    cloud_policy = {"legacy_sync_off": True} if automatic else {"cloud_off": True}
    return {"version": version, **cloud_policy, "backup_automatic_off": not automatic,
            "backup_idle": durability.get("running") is False,
            "native": {**{name: native[name] for name in COUNTERS}, "writer_failed": False}}


def wait_health(sock, version, pid, seconds=120, *, automatic=False):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            return health(sock, version, pid, automatic=automatic)
        except (OSError, http.client.HTTPException, NotReady):
            time.sleep(0.2)
    raise RuntimeError("Run V2 daemon missed its health deadline")
