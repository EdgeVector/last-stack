#!/usr/bin/env python3
"""Bind an upgrade pair to the published Mac package."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


REPO = "EdgeVector/lastdb"
TARGET = "aarch64-apple-darwin"
ARCHIVE = f"lastdb-{TARGET}.tar.gz"
MANIFEST = f"lastdb-{TARGET}.manifest.json"


def github(*args):
    env = {k: v for k, v in os.environ.items() if k not in {"GH_TOKEN", "GITHUB_TOKEN"}}
    result = subprocess.run(["gh", *args], env=env, capture_output=True, timeout=180)
    if result.returncode != 0:
        raise ValueError("GitHub release or qualification evidence is unavailable")
    return result.stdout


def digest(file):
    h = hashlib.sha256()
    with file.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            h.update(chunk)
    return h.hexdigest()


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def main():
    source, version, daemon, cli = sys.argv[1:]
    require(re.fullmatch(r"[0-9a-f]{40}", source), "expected the full LastDB source")
    nightly = re.fullmatch(r"\d+\.\d+\.\d+-nightly\.(\d{8})\.g([0-9a-f]{9})", version)
    if nightly:
        require(source.startswith(nightly[2]), "nightly version does not match source")
        tag, workflow = f"nightly-{nightly[1]}-{nightly[2]}", "nightly-release.yml"
    else:
        require(re.fullmatch(r"\d+\.\d+\.\d+", version), "expected a published nightly or stable version")
        tag, workflow = f"v{version}", "stable-release.yml"
    with tempfile.TemporaryDirectory(prefix="ldb-native-release-") as folder:
        github("release", "download", tag, "-R", REPO, "--pattern", ARCHIVE,
               "--pattern", MANIFEST, "--dir", folder)
        bundle, manifest_path = Path(folder) / ARCHIVE, Path(folder) / MANIFEST
        for path in (bundle, manifest_path):
            fields = ["--repo", REPO, "--signer-workflow", f"{REPO}/.github/workflows/{workflow}",
                      "--signer-digest", source, "--source-digest", source, "--deny-self-hosted-runners"]
            github("attestation", "verify", str(path), *fields)
        manifest = json.loads(manifest_path.read_text())
        require(manifest["schema"] == "lastdb.mini.bundle.v1" and manifest["source_git_oid"] == source
                and manifest["target"] == TARGET and manifest["version"] == version,
                "the published Mac manifest differs")
        require(manifest["artifact"] == {"file": ARCHIVE, "sha256": digest(bundle),
                                         "size": bundle.stat().st_size},
                "the published archive differs from its attested manifest")
        expected = [{"name": name, "sha256": digest(Path(path)),
                     "version": version, "size": Path(path).stat().st_size}
                    for name, path in (("lastdb", cli), ("lastdbd", daemon))]
        require(sorted(manifest["binaries"], key=lambda row: row["name"]) == expected,
                "the upgrade pair differs from the attested Mac executable pair")

    checks = ("ci-required", "benchmark-complete")
    found = {name: [] for name in checks}
    for page in range(1, 11):
        response = github("api", f"repos/{REPO}/commits/{source}/check-runs?per_page=100&page={page}&filter=all")
        items = json.loads(response)["check_runs"]
        for row in items:
            if row["app"]["id"] == 15368 and row["head_sha"] == source and row["name"] in found:
                found[row["name"]].append(row)
        if len(items) < 100:
            break
    else:
        raise ValueError("exact-source check history exceeds its page bound")
    for name, rows in found.items():
        latest = max(rows, key=lambda row: row["id"], default={})
        require(latest.get("status") == "completed" and latest.get("conclusion") == "success",
                f"exact-source {name} has not passed")
        print(f"{name} {latest['html_url']}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(f"Native upgrade release refused: {error}") from None
