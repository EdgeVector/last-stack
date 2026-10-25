"""Bind an exact CI artifact source to its accepted main tree or merged PR."""

import json
import os
import re
import subprocess

from native_upgrade_common import require


def command_json(argv):
    result = subprocess.run(argv, capture_output=True, timeout=30, check=False)
    require(result.returncode == 0 and len(result.stdout) <= 2 * 1024 * 1024,
            "Bounded provenance command failed; details withheld")
    return json.loads(result.stdout)


def git(repo, *args):
    graph = {"GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_OBJECT_DIRECTORY",
             "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE",
             "GIT_REPLACE_REF_BASE", "GIT_NAMESPACE", "GIT_ATTR_SOURCE"}
    require(not any(k in graph or k.startswith("GIT_CONFIG") for k in os.environ),
            "Source provenance refuses inherited Git graph or configuration overrides")
    env = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"}
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, timeout=30, env=env)
    require(result.returncode == 0 and len(result.stdout) <= 4 * 1024 * 1024,
            "Source compatibility Git read failed")
    return result.stdout


def github_metadata(path):
    return command_json(["gh", "api", "repos/EdgeVector/lastdb" + path])


def merged_release(evidence, commit, result, metadata=None):
    source, accepted, repo = evidence["source_git_oid"], evidence["accepted_main_commit"], evidence["source_repository"]
    number = evidence["accepted_pull_request"]
    require(type(number) is int and 0 < number < 2**31, "An exact accepted PR number is required")
    read = metadata or github_metadata
    pull = read("/pulls/" + str(number))
    require(pull["merged"] is True and pull["state"] == "closed" and pull["head"]["sha"] == source
            and pull["base"]["ref"] == "main" and pull["base"]["repo"]["full_name"] == "EdgeVector/lastdb"
            and pull["head"]["repo"]["full_name"] == "EdgeVector/lastdb"
            and pull["merge_commit_sha"] == accepted, "The exact CI source PR is not merged into accepted main")
    parents = [p["sha"] for p in commit["parents"]]
    require(len(parents) == 1 and git(repo, "show", "-s", "--format=%P", accepted).decode().strip().split() == parents
            and git(repo, "rev-parse", accepted + "^{tree}").decode().strip() == result["acceptance_tree"],
            "Accepted squash parent or tree differs between GitHub and the source repository")
    keys = git(repo, "config", "--null", "--name-only", "--list").lower().split(b"\0")
    require(not any(k == b"merge.default" or (k.startswith(b"merge.") and k.endswith(b".driver")) for k in keys),
            "Accepted release proof refuses custom merge drivers")
    parent = parents[0]
    base = git(repo, "merge-base", parent, source).decode().strip()
    tree = git(repo, "merge-tree", "--write-tree", parent, source).decode().strip()
    require(re.fullmatch(r"[0-9a-f]{40}", base) is not None
            and re.fullmatch(r"[0-9a-f]{40}", tree) is not None and tree == result["acceptance_tree"],
            "The accepted merge is not the clean exact integration of the reviewed CI source")
    return {**result, "method": "merged_pull_request", "pull_request": number,
            "squash_parent": parent, "merge_base": base}


def accepted_release(evidence, metadata=None):
    source, accepted = evidence["source_git_oid"], evidence["accepted_main_commit"]
    require(re.fullmatch(r"[0-9a-f]{40}", accepted) is not None, "Accepted main commit is absent")
    read = metadata or github_metadata
    commit = read("/commits/" + accepted)
    relation = read("/compare/" + accepted + "...main?per_page=1")
    require(commit["sha"] == accepted and relation["status"] in ("ahead", "identical")
            and relation["merge_base_commit"]["sha"] == accepted, "The accepted commit is not an ancestor of main")
    result = {"artifact_source": source, "artifact_tree": git(
        evidence["source_repository"], "rev-parse", source + "^{tree}").decode().strip(),
        "acceptance_commit": accepted, "acceptance_tree": commit["commit"]["tree"]["sha"]}
    if result["artifact_tree"] == result["acceptance_tree"]:
        return {**result, "method": "identical_accepted_tree"}
    return merged_release(evidence, commit, result, metadata=read)
