"""Exact native5 retirement source, CI and completed-baseline checks."""

from pathlib import Path
import re
import time

from native_upgrade_common import path_id, regular, require, sha
import native_v2_baseline as baseline
import native_v2_gate as legacy
from native_v2_artifact import verify as verify_archive
from native_v2_benchmark import verify as verify_benchmarks
from native_v2_maintenance_blobs import EXACT_BLOBS
from native_v2_maintenance_paths import ADDED, DELETED, MODIFIED
from native_v2_public import PublicMetadata
from native_v2_release import accepted_release, command_json, git

PROFILE = "native5-cloud-retirement-v1"
BUILD_INPUTS = (".github/", ".lastgit/", "scripts/ci/", "scripts/lints/", "scripts/benchmarks/")
RETIRED_BIN = "lastdb_node/src/bin/csync_e2e_write.rs"
RETIRED_BIN_STANZA = (b'[[bin]]\nbench = false\ntest = false\nname = "csync_e2e_write"\n'
                      b'path = "src/bin/csync_e2e_write.rs"\n\n')
# The retired counter-writer lint allow file and the transformed sources, keyed by path_id.
RETIRED_BIN_ALLOW = "b1bcb10be752c9164393a476714ae1428ecc5f30372ec936ca227f3f93fb090d"
EXACT_TRANSFORMS = {
    "a14bdc610efc28af50b5e0e99604ebfc3bbdb8284eae4a2b86ed2e8392e4b0d4": (
        (b"use super::*;\n", b"use super::*;\nuse std::collections::BTreeSet;\n"),
    ),
    "0a1b7a3ffe9717d8ec940ff778ed218a86dcfae02901440578ce5101525469b3": (
        (b"pub(crate) use delete_replay::CUTOFF_KEY as DELETE_REPLAY_CUTOFF_KEY;\n", b""),
        (b"pub(crate) use retired_intent_retention::{\n"
         b"    RetiredIntentRetentionGuard, RetiredIntentRetentionProof,\n};\n",
         b"pub(crate) use retired_intent_retention::RetiredIntentRetentionProof;\n"),
    ),
}


def reader(evidence):
    transport = evidence.get("github_metadata_transport", "gh")
    require(transport in ("gh", "public_https"), "Unknown GitHub metadata transport")
    if transport == "public_https":
        return PublicMetadata()
    return lambda path: command_json(["gh", "api", "repos/EdgeVector/lastdb" + path])


def required_ci(read, source, evidence):
    run_id = evidence.get("required_ci_run")
    require(type(run_id) is int and 0 < run_id < 2**63, "The exact candidate source CI run is absent")
    run = read("/actions/runs/" + str(run_id))
    require(run.get("head_sha") == source and run.get("event") == "workflow_dispatch"
            and run.get("path") == ".github/workflows/ci-required.yml"
            and run.get("status") == "completed" and run.get("conclusion") == "success",
            "The exact candidate source CI dispatch did not succeed")
    page = read("/actions/runs/" + str(run_id) + "/jobs?per_page=100")
    jobs = page.get("jobs", [])
    require(type(page.get("total_count")) is int and page["total_count"] == len(jobs) <= 100,
            "Candidate CI job enumeration is incomplete")
    matches = [value for value in jobs if value.get("name") == "ci-required"]
    require(len(matches) == 1 and matches[0].get("run_id") == run_id
            and matches[0].get("status") == "completed" and matches[0].get("conclusion") == "success",
            "The candidate source required job did not succeed")
    url = matches[0].get("check_run_url", "")
    match = re.fullmatch(r"https://api\.github\.com/repos/EdgeVector/lastdb/check-runs/([1-9][0-9]{0,18})", url)
    require(match is not None, "Candidate CI check does not belong to the fixed repository")
    check = read("/check-runs/" + match[1])
    require(check.get("head_sha") == source and check.get("name") == "ci-required"
            and check.get("status") == "completed" and check.get("conclusion") == "success"
            and check.get("app", {}).get("slug") == "github-actions", "Candidate CI check authority differs")
    return {"source": source, "run_id": run_id, "check_run_id": check["id"]}


def accepted_ci(read, source):
    page = read("/commits/" + source + "/check-runs?filter=latest&per_page=100")
    rows = page.get("check_runs", [])
    require(type(page.get("total_count")) is int and page["total_count"] == len(rows) <= 100,
            "Accepted main CI check enumeration is incomplete")
    result = {}
    for name in ("ci-required", "benchmark-complete"):
        matches = [value for value in rows if value.get("name") == name]
        require(len(matches) == 1 and matches[0].get("head_sha") == source
                and matches[0].get("status") == "completed" and matches[0].get("conclusion") == "success"
                and matches[0].get("app", {}).get("slug") == "github-actions", "Accepted main gate failed: " + name)
        result[name] = matches[0]["id"]
    return {"source": source, "check_run_ids": result}


def artifact(candidate, evidence, read):
    source = evidence["source_git_oid"]
    receipt = legacy.private_json(evidence["artifact_receipt"], 16384)
    require(receipt["source"] == source and receipt["programs"] ==
            {"bin/" + key: value["sha256"] for key, value in candidate.items()}, "CI artifact and pair differ")
    require(all(type(receipt.get(key)) is int and 0 < receipt[key] < 2**63 for key in ("artifact_id", "run"))
            and re.fullmatch(r"sha256:[0-9a-f]{64}", receipt.get("github_archive_sha256", "")) is not None,
            "The exact candidate artifact identifiers or archive digest are invalid")
    value = read("/actions/artifacts/" + str(receipt["artifact_id"]))
    require(value.get("expired") is False and value["digest"] == receipt["github_archive_sha256"]
            and value["workflow_run"]["head_sha"] == source and value["workflow_run"]["id"] == receipt["run"]
            and value["name"] == "lastdb-native-dev-arm64-" + source
            and type(value.get("size_in_bytes")) is int and 0 < value["size_in_bytes"] <= 512 * 1024 * 1024,
            "The exact unexpired candidate Mac artifact provenance differs")
    run = read("/actions/runs/" + str(receipt["run"]))
    require(run["head_sha"] == source and run["status"] == "completed" and run["conclusion"] == "success"
            and run["path"] == ".github/workflows/native-dev-artifact.yml", "The candidate Mac artifact run differs")
    regular(evidence["artifact_archive"], private=True, maximum=512 * 1024 * 1024)
    require(Path(evidence["artifact_archive"]).stat().st_size == value["size_in_bytes"]
            and sha(evidence["artifact_archive"]) == value["digest"].removeprefix("sha256:")
            and Path(receipt["bin_dir"]) == Path(candidate["lastdb"]["path"]).parent,
            "The retained verified candidate archive or program directory differs")
    verify_archive(evidence["artifact_archive"], source, candidate)
    return {"source": source, "run_id": receipt["run"], "artifact_id": receipt["artifact_id"],
            "github_archive_sha256": value["digest"]}


def source_tree(repo, source):
    result = {}
    for record in git(repo, "ls-tree", "-r", "-z", source).split(b"\0"):
        if record:
            header, name = record.decode().split("\t", 1)
            mode, kind, oid = header.split()
            result[name] = (mode, kind, oid)
    return result


def fixture_stanza_only(repo, source, old, new):
    require(RETIRED_BIN in old and RETIRED_BIN not in new, "The retired fixture source must be removed")
    before = git(repo, "show", baseline.SOURCE + ":lastdb_node/Cargo.toml")
    after = git(repo, "show", source + ":lastdb_node/Cargo.toml")
    require(before.count(RETIRED_BIN_STANZA) == 1
            and after == before.replace(RETIRED_BIN_STANZA, b"", 1),
            "Cargo changes exceed the exact retired fixture stanza deletion")


def exact_source_change(repo, source, name):
    before = git(repo, "show", baseline.SOURCE + ":" + name)
    after = git(repo, "show", source + ":" + name)
    expected = before
    for original, replacement in EXACT_TRANSFORMS[path_id(name)]:
        require(expected.count(original) == 1, "An exact maintenance source transform is absent or duplicated")
        expected = expected.replace(original, replacement, 1)
    require(after == expected, "A maintenance source change exceeds its exact byte transform")


def compatibility(evidence):
    require(isinstance(evidence.get("compatibility_sha256"), str)
            and re.fullmatch(r"[0-9a-f]{64}", evidence["compatibility_sha256"]) is not None,
            "The fresh reviewed compatibility hash is absent")
    proof = legacy.private_json(evidence["compatibility_record"], 256 * 1024,
                                expected_sha256=evidence["compatibility_sha256"])
    source = evidence["source_git_oid"]
    require(proof.get("schema") == "lastdb.native-source-compatibility.v1" and proof.get("profile") == PROFILE
            and proof.get("baseline") == baseline.SOURCE and proof.get("candidate") == source
            and proof.get("source_reviewed") is True and proof.get("no_native_format_change") is True
            and proof.get("restore_migration_disallowed") is True, "Fresh exact96 source compatibility review is absent")
    old = source_tree(evidence["source_repository"], baseline.SOURCE)
    new = source_tree(evidence["source_repository"], source)
    changes = {}
    for name in old.keys() | new.keys():
        before, after = old.get(name), new.get(name)
        protected = name.startswith(legacy.PROTECTED + BUILD_INPUTS) or Path(name).name in (
            "Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "build.rs") or name.startswith(".cargo/")
        if not protected or before == after:
            continue
        name_id = path_id(name)
        if name_id in EXACT_BLOBS:
            require((before, after) == EXACT_BLOBS[name_id],
                    "A sensitive maintenance source differs from its exact reviewed Git blobs: " + name)
            if name_id == RETIRED_BIN_ALLOW:
                require(RETIRED_BIN in old and RETIRED_BIN not in new,
                        "The retired fixture lint entry requires deletion of its exact source")
        elif before is None:
            require(name in ADDED and after[:2] == ("100644", "blob"), "Unreviewed maintenance source addition: " + name)
        elif after is None:
            require(name in DELETED, "Unreviewed maintenance source deletion: " + name)
        else:
            require((name in MODIFIED or name_id in EXACT_TRANSFORMS or name == "lastdb_node/Cargo.toml")
                    and before[:2] == after[:2] == ("100644", "blob"),
                    "An unreviewed writer, native format, feature, build input or dependency changed: " + name)
            if name == "lastdb_node/Cargo.toml":
                fixture_stanza_only(evidence["source_repository"], source, old, new)
            elif name_id in EXACT_TRANSFORMS:
                exact_source_change(evidence["source_repository"], source, name)
        changes[name] = {"before": before[2] if before else None, "after": after[2] if after else None}
    require(proof.get("reviewed_format_neutral_changes") == changes, "Fresh exact96 reviewed source blobs differ")
    return {"baseline": baseline.SOURCE, "candidate": source, "profile": PROFILE,
            "format_neutral_changes": len(changes), "record_sha256": evidence["compatibility_sha256"],
            "backward_reopen_exercised": False}


def check(candidate, evidence, current, approval):
    require(evidence.get("maintenance_profile") == PROFILE, "The exact96 maintenance policy is not explicit")
    predecessor = baseline.check(evidence, current, approval)
    read = reader(evidence)
    release = accepted_release(evidence, metadata=read)
    require(release.get("method") == "merged_pull_request",
            "The native5 maintenance artifact requires its exact merged main PR")
    ci = required_ci(read, evidence["source_git_oid"], evidence)
    normal = accepted_ci(read, evidence["accepted_main_commit"])
    benchmarks = verify_benchmarks(read, evidence, normal)
    package = artifact(candidate, evidence, read)
    return {"release_acceptance": release, "candidate_source_ci": ci, "accepted_main_ci": normal,
            "benchmarks": benchmarks,
            "artifact": package, "baseline_provenance": predecessor,
            "development": legacy.development(candidate, evidence), "compatibility": compatibility(evidence),
            "benchmark_source": evidence["accepted_main_commit"], "checked_at": int(time.time())}
