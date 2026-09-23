"""Resolve fold's forge-promote-homebrew-stable.sh for a stable publish.

The promote script is fold code, so it comes from fold's Forgejo main, read
through the portal's bare mirror (~/.cache/edgevector-git/fold.git) after a
fresh fetch. It is exported with `git archive` into a scratch directory, so
the script's sibling files (bump-homebrew-formula.rb) come from the same
commit.

Never ~/.lastgit/mirrors/*: that checkout froze at fold 06965ddf on
2026-09-02, when LastGit repos were disabled
(decision-2026-09-06-all-repos-venue-forgejo-no-lastgit-default). Its script
cloned lastdb:///homebrew-lastdb and exited 128, and every automatic stable
publish after it failed
(papercut-release-publish-uses-stale-lastgit-fold-mirror-20260923).

A script that names a `lastdb:///` remote is refused, wherever it came from.
"""
from __future__ import annotations

import os
import subprocess
import tarfile
import tempfile
import io
from pathlib import Path

SCRIPT_REL = "scripts/release/forge-promote-homebrew-stable.sh"
MAIN_REF = "refs/remotes/origin/main"
FORGE_PREFIXES = ("http://localhost:3300/", "http://127.0.0.1:3300/")


class PromoteScriptError(RuntimeError):
    """The promote script cannot be resolved, or it is refused."""


def default_mirror() -> Path:
    return Path(
        os.environ.get("LAST_STACK_FOLD_GIT_MIRROR", str(Path.home() / ".cache/edgevector-git/fold.git"))
    )


def _git(mirror: Path, args: list[str], header: list[str] | None = None, timeout: int = 180,
         binary: bool = False) -> subprocess.CompletedProcess:
    cmd = ["git", *(header or []), "--git-dir", str(mirror), *args]
    return subprocess.run(cmd, capture_output=True, text=not binary, timeout=timeout, check=False)


def check_script(path: Path) -> Path:
    """Refuse a LastGit-era mirror path, and a script that names a lastdb:/// remote."""
    resolved = path.resolve()
    if "/.lastgit/mirrors/" in f"{resolved}/" or "/.lastgit/mirrors/" in f"{path}/":
        raise PromoteScriptError(
            f"refusing {path}: ~/.lastgit/mirrors is a frozen LastGit-era checkout "
            "(decision-2026-09-06-all-repos-venue-forgejo-no-lastgit-default); "
            "the promote script comes from fold's Forgejo main"
        )
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        raise PromoteScriptError(f"cannot read promote script {path}: {exc}") from exc
    if "lastdb:///" in text:
        raise PromoteScriptError(
            f"refusing {path}: it names a lastdb:/// remote, and LastGit repos are disabled "
            "(decision-2026-09-06-all-repos-venue-forgejo-no-lastgit-default). "
            "Use fold's Forgejo main, which targets the Forgejo homebrew-lastdb tap"
        )
    return path


def resolve_from_mirror(mirror: Path, dest: Path, auth_header: list[str] | None = None,
                        fetch: bool = True) -> tuple[Path, str]:
    """Fetch fold main into the bare mirror, export scripts/release at it, return (script, oid)."""
    if not (mirror / "HEAD").is_file():
        raise PromoteScriptError(
            f"no fold bare mirror at {mirror}; run `./bin/wt fetch` in the fold portal "
            "or set LAST_STACK_FOLD_GIT_MIRROR"
        )
    if fetch:
        origin = _git(mirror, ["config", "--get", "remote.origin.url"]).stdout.strip()
        header = auth_header if origin.startswith(FORGE_PREFIXES) else []
        last = None
        for _ in range(2):  # one retry: a sibling `wt fetch` can hold the ref lock
            last = _git(mirror, ["fetch", "--quiet", "origin", f"+refs/heads/main:{MAIN_REF}"], header=header)
            if last.returncode == 0:
                break
        if last is None or last.returncode != 0:
            err = (last.stderr.strip() if last else "") or "no output"
            raise PromoteScriptError(f"fetch of fold main into {mirror} failed: {err}")
    oid = _git(mirror, ["rev-parse", "--verify", f"{MAIN_REF}^{{commit}}"]).stdout.strip()
    if not oid:
        raise PromoteScriptError(f"{mirror} has no {MAIN_REF}")
    archive = _git(mirror, ["archive", "--format=tar", oid, "scripts/release"], binary=True)
    if archive.returncode != 0:
        err = archive.stderr.decode("utf-8", "replace").strip()
        raise PromoteScriptError(f"fold {oid[:12]} has no scripts/release: {err}")
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tar:
        for member in tar.getmembers():
            if member.name.startswith("/") or ".." in Path(member.name).parts:
                raise PromoteScriptError(f"unsafe path in fold archive: {member.name}")
        tar.extractall(dest)
    script = dest / SCRIPT_REL
    if not script.is_file():
        raise PromoteScriptError(f"fold {oid[:12]} has no {SCRIPT_REL}")
    return check_script(script), oid


def resolve(explicit: str | None, auth_header: list[str] | None = None,
            dest: Path | None = None) -> tuple[Path, str]:
    """Explicit path (flag or $LAST_STACK_CANARY_FORGE_PROMOTE), else fold's Forgejo main.

    Returns (script path, source description)."""
    for candidate in (explicit, os.environ.get("LAST_STACK_CANARY_FORGE_PROMOTE", "")):
        if candidate:
            path = Path(candidate)
            if not path.is_file():
                raise PromoteScriptError(f"promote script {path} does not exist")
            return check_script(path), f"explicit {path}"
    mirror = default_mirror()
    if dest is None:
        dest = Path(tempfile.mkdtemp(prefix="fold-promote-script."))
    script, oid = resolve_from_mirror(mirror, dest, auth_header=auth_header)
    return script, f"fold origin/main {oid[:12]} via {mirror}"
