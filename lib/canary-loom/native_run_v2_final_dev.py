"""Require the actual stopped backup and its separate source-free DEV restore."""
from pathlib import Path

from native_upgrade_common import alive, require
from native_run_v2_inputs import read, reference, uint
from native_run_v2_maintenance_dev import check as automatic


def check(candidate, evidence, limit):
    result = automatic(candidate, evidence, limit)
    proof = read(evidence["development_proof"], 262144, evidence["development_sha256"])
    final = proof["stopped_backup"]
    summary, intent = reference(proof["summary"]), reference(final["intent"])
    report = reference(final["report"])
    operation = proof["intent"]["sha256"]
    programs = {name: value["sha256"] for name, value in candidate.items()}
    homes = Path(summary["homes"])
    original = reference(proof["consumers"]["baseline-after-candidate"]["stop"])
    require(summary.get("stopped_backup_and_restore") is True
            and intent.get("source") == summary["source"] and intent.get("programs") == programs
            and intent.get("home") == str(homes / "s") and intent.get("stop") == original
            and intent.get("operation_sha256") == operation and report.get("request") == {
                "request_id": intent["request_id"], "account_id": summary["account"],
                "stopped_pid": original["owner"]["pid"], "stopped_start_ts": original["owner"]["start_ts"]},
            "The final DEV backup is not bound to the baseline's exact clean stop")
    require(report.get("version") == 1 and report.get("automatic_backup_enabled") is False
            and all(report.get(k) is True for k in (
                "all_remote_file_hashes_verified", "source_released", "native_cut_unchanged"))
            and all(intent["current_sha256"][name] == report["run_profile"][label]["current_sha256"]
                    for name, label in (("disk-run", "main"), ("disk-cas", "cas"))),
            "The stopped DEV backup lacks complete provider readback or unchanged native roots")
    accepted = report["accepted_backup"]
    interrupted, resumed = reference(final["before_resume"]), reference(final["after_resume"])
    require(interrupted.get("request_id") == resumed.get("request_id") == intent["request_id"]
            and interrupted.get("source") == summary["source"]
            and interrupted.get("programs") == programs and interrupted.get("operation_sha256") == operation
            and interrupted.get("marker_links") == 2 and resumed.get("marker_links") == 1
            and resumed.get("same_request_resume") is True and resumed.get("accepted_backup") == accepted
            and interrupted["core_begin"] == accepted["begin"] and not alive(interrupted["cli_pid"]),
            "The actual interrupted final source did not resume the same request and release its marker link")
    restore = reference(final["restore"])
    require(restore.get("commit_sha256") == accepted["commit_sha256"]
            and restore.get("destination") == str(homes / "t")
            and restore.get("file_dependencies_verified") is True
            and uint(restore.get("verified_atoms"), True) > 0,
            "The accepted stopped DEV snapshot did not restore into its absent home")
    native = reference(final["native_files"])
    require(native.get("accepted_backup") == accepted and native.get("before_first_boot") is True
            and native.get("destination") == str(homes / "t")
            and len(native["files"]) == report["native_files"]
            and sum(uint(f["bytes"], True) for f in native["files"]) == report["native_bytes"],
            "The full native stopped snapshot was not verified before its first boot")
    provider = reference(proof["provider_accounting"])
    checkpoint = [c for c in provider["checkpoints"] if c["request_id"] == intent["request_id"]]
    require(len(checkpoint) == 1 and checkpoint[0]["accepted_backup"] == accepted,
            "The independent whole-account provider proof excludes the final stopped snapshot")
    remote = reference({"path": checkpoint[0]["provider"], "sha256": checkpoint[0]["provider_sha256"]})
    require(sorted(remote.get("native_files_verified", []), key=lambda f: f["path"])
            == sorted(native["files"], key=lambda f: f["path"]),
            "The independently reconstructed provider files differ from the actual restored native files")
    sessions = set()
    for label in ("stopped-restored-first", "stopped-restored-second"):
        owner = reference(final["consumers"][label]["owner"])
        identity = (owner["pid"], owner["start_ts"])
        require(identity not in sessions, "The final restored DEV starts reuse one session")
        sessions.add(identity)
        consumer(final["consumers"][label], final["reads"][label], candidate, summary,
                 homes / "t", operation, accepted, label,
                 reference(proof["reads"]["restored-second"])["records_sha256"])
    result["final_stopped_backup_and_source_free_restore"] = True
    return result


def consumer(refs, read_ref, candidate, summary, home, operation, accepted, label, expected_digest):
    owner, stop, observed = reference(refs["owner"]), reference(refs["stop"]), reference(read_ref)
    identity = {"pid": uint(owner["pid"], True), "start_ts": uint(owner["start_ts"], True)}
    programs = {name: value["sha256"] for name, value in candidate.items()}
    require(owner.get("source") == summary["source"] and owner.get("programs") == programs
            and owner.get("home") == str(home) and owner.get("account") == summary["account"]
            and owner.get("operation_sha256") == operation and stop.get("owner") == owner
            and stop.get("receipt") == {"version": 1, **identity, "flush_ok": True}
            and all(stop.get("session", {}).get(k) == v for k, v in identity.items())
            and stop["session"].get("exit") == "clean" and not alive(identity["pid"]),
            "A final restored DEV consumer lacks its exact client, home, or clean stop")
    require(observed.get("session") == identity and observed.get("home") == str(home)
            and observed.get("source") == summary["source"] and observed.get("programs") == programs
            and observed.get("stage") == label and observed.get("operation_sha256") == operation
            and observed.get("accepted_commit_sha256") == accepted["commit_sha256"]
            and observed.get("records_sha256") == expected_digest
            and (observed.get("existing_records"), observed.get("absent_records")) == (14, 2)
            and observed.get("exact_keyed_values") is True and observed.get("full_file_bytes_equal") is True
            and observed.get("files") == summary["full_CAS_file_bytes"],
            "A final restored DEV read differs from the exact records, deletions, or full file bytes")
