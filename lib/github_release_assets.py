#!/usr/bin/env python3
"""Download exact GitHub release assets through REST, without GraphQL."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote


def github_env():
    return {k: v for k, v in os.environ.items() if k not in {"GH_TOKEN", "GITHUB_TOKEN"}}


def download(repo, tag, destination, names):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo) or not tag \
            or any(part in {".", ".."} for part in repo.split("/")):
        raise ValueError("invalid release locator")
    if not names or len(set(names)) != len(names) or any(
        not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name) for name in names
    ):
        raise ValueError("expected distinct asset filenames")
    env = github_env()
    command = ["gh", "api", "--hostname", "github.com"]
    result = subprocess.run(
        [*command, f"repos/{repo}/releases/tags/{quote(tag, safe='')}"],
        capture_output=True, timeout=180, env=env, check=True,
    )
    release = json.loads(result.stdout)
    if release.get("draft") is not False or release.get("tag_name") != tag:
        raise ValueError("expected the published exact release")
    assets = release.get("assets")
    if not isinstance(assets, list) or len(assets) > 1000:
        raise ValueError("invalid release asset inventory")
    destination.mkdir(parents=True, exist_ok=True)
    for name in names:
        matches = [asset for asset in assets if asset.get("name") == name]
        if len(matches) != 1:
            raise ValueError("release asset missing or ambiguous")
        asset = matches[0]
        if type(asset.get("id")) is not int or asset["id"] <= 0 \
                or type(asset.get("size")) is not int or asset["size"] <= 0:
            raise ValueError("invalid release asset identity or size")
        output = destination / name
        temporary = None
        if output.exists() or output.is_symlink():
            raise ValueError("release asset destination already exists")
        try:
            with tempfile.NamedTemporaryFile(
                prefix=f".{name}.", suffix=".part", dir=destination, delete=False,
            ) as stream:
                temporary = Path(stream.name)
                subprocess.run(
                    [*command, "-H", "Accept: application/octet-stream",
                     f"repos/{repo}/releases/assets/{asset['id']}"],
                    stdout=stream, stderr=subprocess.PIPE, env=env,
                    timeout=180, check=True,
                )
            if temporary.stat().st_size != asset["size"]:
                raise ValueError("downloaded release asset size differs")
            # Publish without overwriting any other consumer's file.
            os.link(temporary, output, follow_symlinks=False)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("assets", nargs="+")
    args = parser.parse_args()
    try:
        download(args.repo, args.tag, args.destination, args.assets)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        parser.exit(1, "GitHub REST release asset download failed\n")


if __name__ == "__main__":
    main()
