"""The accepted health gates with an explicit expected account, never a global override."""
from concurrent.futures import ThreadPoolExecutor

from native_run_v2_auto_qualify_io import BASELINE, BASELINE_PROGRAMS, read, require


def health(node, account, readiness=False):
    paths = ("/health", "/api/status", "/api/system/boot-identity", "/api/db/native-status")
    with ThreadPoolExecutor(max_workers=4) as pool:
        basic, status, boot, native = list(pool.map(node.call, paths))
    require(node.process is not None and node.process.poll() is None, "owned_health_child")
    instance, prefix = basic["instance_id"], str(node.process.pid) + "-"
    require(basic["status"] == "ok" and isinstance(instance, str) and instance.startswith(prefix)
            and instance[len(prefix):].isdigit() and int(instance[len(prefix):]) > 0
            and node.instance_id in (None, instance), "owned_health_instance")
    require(status["user_hash"] == account and status["status"]["build"]["version"] == node.programs.version
            and boot["pid"] == node.process.pid and boot["build"] == node.programs.version,
            "explicit_account_and_pair")
    start = boot["process_start_ts"]
    require(type(start) is int and start > 0 and node.start_ts in (None, start), "exact_boot_identity")
    from native_run_v2_auto_qualify_process import ledger
    identity = {"pid": node.process.pid, "start_ts": start}
    current = read(node.home / "current-session.json", 4096)
    rows = [row for row in ledger(node.home) if all(row.get(k) == v for k, v in identity.items())]
    require(all(current.get(k) == v for k, v in identity.items()) and len(rows) == 1
            and rows[0].get("exit") is None, "actual_current_session_and_ledger")
    host_start = status["status"]["process_start_ts"]
    if node.programs.source == BASELINE and node.programs.expected == BASELINE_PROGRAMS:
        require(type(host_start) is int and host_start > 0, "baseline_host_timestamp_observed")
    else:
        require(host_start == start, "candidate_single_record_start_identity")
    node.host_start_ts = host_start
    node.start_ts, node.instance_id = start, instance
    measured = status["status"]
    require(native["native_disk"]["writer_failed"] is False, "native_health")
    durability = measured["durability"]
    if not node.backup_source:
        require(durability["automatic_enabled"] is False and durability["running"] is False,
                "restored_backup_off")
    node.offline()
    if readiness and durability["observed"] is False:
        return False
    require(durability["observed"] is True, "observed_durability")
    return True
