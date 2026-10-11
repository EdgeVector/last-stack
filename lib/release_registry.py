"""Stable registry preparation and publication, with no local secret file."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import uuid
from pathlib import Path

# Same public release identity as LastDB's RELEASE_INDEX_PUBKEY_B64. No rotation.
RELEASE_PUBLIC_IDENTITY = "Aw807ErGvi7+cJ0RhSvRbAt9UWwKOwrfAPvAYF4fNdQ="
TAP_REPO = "EdgeVector/homebrew-lastdb"
TAP_URL = f"https://github.com/{TAP_REPO}.git"


class Refused(RuntimeError):
    """A static safe release refusal."""


def command(args, **kwargs):
    kwargs.setdefault("timeout", 120)
    try:
        result = subprocess.run(args, capture_output=True, text=True, check=False, **kwargs)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refused("release command unavailable or timed out") from exc
    if result.returncode:
        raise Refused("release command refused; private child output is not copied")
    return result.stdout.strip()


def binary_and_trust(selected):
    binary = selected or os.environ.get("LASTDB_BIN") or shutil.which("lastdb")
    if not binary:
        raise Refused("a LastDB binary is required")
    command([binary, "app", "index", "sign", "--help"])
    if command([binary, "app", "index", "trust-key"]) != RELEASE_PUBLIC_IDENTITY:
        raise Refused("LastDB does not carry the existing release trust identity")
    return binary


def signing_source(locator):
    match = re.fullmatch(r"lastsecrets://([A-Za-z0-9][A-Za-z0-9_.-]{0,127})", locator or "")
    if not match:
        raise Refused("the existing signing key needs a lastsecrets:// locator")
    binary = os.environ.get("LASTSECRETS_BIN", "lastsecrets")
    if not shutil.which(binary):
        raise Refused("LastSecrets is unavailable")
    return binary, match.group(1)


def sign(index, binary, locator):
    secret_binary, slug = signing_source(locator)
    source = None
    sink = None
    try:
        source = subprocess.Popen([secret_binary, "get", slug], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL)
        sink = subprocess.Popen([binary, "app", "index", "sign", "--index", str(index),
                                 "--key-file", "/dev/stdin"], stdin=source.stdout,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        source.stdout.close()
        sink_code = sink.wait(timeout=120)
        source_code = source.wait(timeout=10)
        if source_code or sink_code:
            raise Refused("LastSecrets or registry signature refused")
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Refused("LastSecrets or registry signer unavailable or timed out") from exc
    finally:
        for child in (sink, source):
            if child is not None and child.poll() is None:
                child.kill()
                child.wait()
    verify(index, binary)


def verify(index, binary):
    command([binary, "app", "index", "verify", "--index", str(index),
             "--trust-key", RELEASE_PUBLIC_IDENTITY])


def read_index(path):
    if not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
        raise Refused("registry index missing or exceeds the declared 16 MiB bound")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise Refused("registry index is invalid") from exc
    if not isinstance(value, dict) or not isinstance(value.get("apps"), list):
        raise Refused("registry index shape is invalid")
    return value



def registered_dev(root):
    """Check the portal's exact marker and reciprocal Git registration."""
    expected_root = (Path.home() / ".fkanban/worktrees").resolve()
    portal = Path.home() / "code/edgevector/homebrew-lastdb/.portal"
    if root.parent != expected_root or not (root / ".git").is_file():
        raise Refused("publication needs a portal DEV root under ~/.fkanban/worktrees")
    try:
        values = {}
        marker = root / ".portal-worktree"
        if not marker.is_file() or marker.stat().st_size > 4096:
            raise ValueError
        for line in marker.read_text(encoding="utf-8").splitlines():
            key, value = line.split("=", 1)
            if key in values:
                raise ValueError
            values[key] = value
        if set(values) != {"slug", "branch", "created"} or values["slug"] != "homebrew-lastdb":
            raise ValueError
        branch = command(["git", "-C", str(root), "symbolic-ref", "--short", "HEAD"])
        if values["branch"] != branch or root.name != "homebrew-lastdb-" + branch.replace("/", "-"):
            raise ValueError
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", values["created"]):
            raise ValueError
        if command(["git", "-C", str(root), "ls-files", "--", ".portal-worktree"]):
            raise ValueError
        command(["git", "-C", str(root), "check-ignore", "-q", ".portal-worktree"])
        for name, expected in (("slug", "homebrew-lastdb"), ("venue", "github")):
            if (portal / name).read_text(encoding="utf-8").strip() != expected:
                raise ValueError
        cache_text = (portal / "cache").read_text(encoding="utf-8").strip()
        if not cache_text or len(cache_text) > 4096 or not Path(cache_text).is_absolute():
            raise ValueError
        cache = Path(cache_text).resolve()
        common = Path(command(["git", "-C", str(root), "rev-parse", "--git-common-dir"]))
        if (root / common).resolve() != cache:
            raise ValueError
        admin = Path(command(["git", "-C", str(root), "rev-parse", "--absolute-git-dir"])).resolve()
        if admin.parent != cache / "worktrees":
            raise ValueError
        if (root / ".git").read_text(encoding="utf-8").strip() != "gitdir: " + str(admin):
            raise ValueError
        if Path((admin / "gitdir").read_text(encoding="utf-8").strip()).resolve() != root / ".git":
            raise ValueError
        if (admin / (admin / "commondir").read_text(encoding="utf-8").strip()).resolve() != cache:
            raise ValueError
        if command(["git", "--git-dir", str(cache), "rev-parse", "--is-bare-repository"]) != "true":
            raise ValueError
    except (OSError, ValueError, KeyError) as exc:
        raise Refused("publication portal marker or exact Git registration refused") from exc


def clean_dev(path, fetch=True, expected_head=None):
    if not path:
        raise Refused("publication needs an explicit registered DEV worktree")
    root = Path(path).resolve()
    registered_dev(root)
    if command(["git", "-C", str(root), "rev-parse", "--show-toplevel"]) != str(root):
        raise Refused("publication path is not the DEV worktree root")
    if command(["git", "-C", str(root), "status", "--porcelain"]):
        raise Refused("publication DEV worktree is not clean")
    for flags in ([], ["--push"]):
        if command(["git", "-C", str(root), "remote", "get-url", *flags, "--all", "origin"]) != TAP_URL:
            raise Refused("publication origin differs from the exact GitHub tap")
    venue = root / ".last-stack/pr-venue"
    if not venue.is_file() or venue.read_text(encoding="utf-8").splitlines()[:1] != ["github"]:
        raise Refused("publication source does not declare the GitHub venue")
    command(["last-stack-pr-venue", TAP_REPO, str(root)])
    if fetch:
        command(["git", "-C", str(root), "fetch", "--quiet", "origin", "main"])
    head = command(["git", "-C", str(root), "rev-parse", "HEAD"])
    target = expected_head or command(["git", "-C", str(root), "rev-parse", "origin/main"])
    if head != target or not re.fullmatch(r"[0-9a-f]{40}", head):
        raise Refused("publication DEV worktree is not at the selected accepted main")
    return root, head


def scratch_tap(root):
    command(["git", "clone", "--quiet", "--depth", "1", TAP_URL, str(root)])
    return root


def verify_mini_source(oid):
    import fold_promote_script

    mirror = fold_promote_script.default_mirror()
    if not (mirror / "HEAD").is_file():
        raise Refused("the accepted public LastDB source mirror is unavailable")
    prefix = ["git", "--git-dir", str(mirror)]
    command([*prefix, "fetch", "--quiet", "https://github.com/EdgeVector/lastdb.git",
             "+refs/heads/main:refs/remotes/origin/main"], timeout=180)
    command([*prefix, "merge-base", "--is-ancestor", oid, "refs/remotes/origin/main"])


def prepare(root, tap, build, oid, binary, locator, scratch, skip_registry=False):
    import release_proofs

    source_index = tap / "registry" / ("stable.json" if skip_registry else "next.json")
    verify(source_index, binary)
    verify_mini_source(oid)
    selected = release_proofs.selected_rows(read_index(source_index), build)
    release_proofs.verify_hosted(root, tap, selected, build, oid, scratch)
    if skip_registry:
        return None
    signing_source(locator)
    target = scratch / "stable.json"
    shutil.copy2(tap / "registry/stable.json", target)
    shutil.copy2(tap / "registry/stable.json.sig", scratch / "stable.json.sig")
    verify(target, binary)
    source_map = scratch / "source-map.json"
    config = json.loads((root / "config/registry/apps.json").read_text(encoding="utf-8"))
    mapping = {app: str(value.get("public") or "") for app, value in config["apps"].items()
               if value.get("public")}
    source_map.write_text(json.dumps(mapping), encoding="utf-8")
    command([str(root / "bin/last-stack-registry-index"), "promote",
             "--source-index", str(source_index), "--target-index", str(target),
             "--lastdb-version", build, "--source-map", str(source_map),
             "--require-source-map", "--verify-reachable"], timeout=600)
    prepared_rows = release_proofs.selected_rows(read_index(target), build)
    if not set(selected).issubset(prepared_rows):
        raise Refused("prepared stable rows differ from the verified hosted proof")
    if prepared_rows != selected:
        release_proofs.verify_hosted(root, tap, prepared_rows, build, oid, scratch / "prior-proofs")
    sign(target, binary, locator)
    return target


def publish(tap, base, prepared, build, tag, out_dir, state):
    clean_dev(str(tap), fetch=False, expected_head=base)
    branch = f"registry/stable-{tag}-{uuid.uuid4()}"
    state.stage("registry", "branch_requested", tap_root=str(tap), tap_base=base, branch=branch)
    command(["git", "-C", str(tap), "checkout", "--quiet", "-b", branch])
    state.stage("registry", "branch_created")
    for name in ("stable.json", "stable.json.sig"):
        shutil.copy2(prepared.parent / name, tap / "registry" / name)
    command(["git", "-C", str(tap), "add", "-A"])
    state.stage("registry", "commit_requested")
    command(["git", "-C", str(tap), "commit", "--quiet", "-m",
             f"registry(stable): verified LastDB {build} ({tag})"])
    if command(["git", "-C", str(tap), "status", "--porcelain"]):
        raise Refused("registry commit did not preserve all prepared changes")
    head = command(["git", "-C", str(tap), "rev-parse", "HEAD"])
    state.stage("registry", "commit_created", head=head)
    command(["last-stack-pr-venue", TAP_REPO, str(tap)])
    state.stage("registry", "push_requested")
    command(["git", "-C", str(tap), "push", "--quiet", "-u", "origin", branch])
    state.stage("registry", "branch_pushed")
    body = out_dir / f"registry-pr-{tag}.md"
    body.write_text(f"Promote the signed next rows proved with LastDB `{build}` to stable.\n\n"
                    "The publisher verifies the current real GitHub install/startup proof, exact Mini/app OIDs, "
                    "public-source reachability and the existing release trust key before either public step. "
                    "The primary quiet-window decision stays unchanged. Normal required tap CI controls merge.\n",
                    encoding="utf-8")
    state.stage("registry", "pr_requested")
    url = command(["gh", "pr", "create", "--repo", TAP_REPO, "--base", "main", "--head", branch,
                   "--title", f"registry(stable): LastDB {build} ({tag})", "--body-file", str(body)])
    if not re.fullmatch(r"https://github.com/EdgeVector/homebrew-lastdb/pull/[0-9]+", url):
        raise Refused("registry PR response is not the exact GitHub tap PR")
    state.stage("registry", "pr_created", tap_pr_url=url)
    state.summary["registry"] = url
    state.save()
    state.stage("registry", "auto_arm_requested")
    command(["gh", "pr", "merge", url, "--repo", TAP_REPO, "--squash", "--auto", "--match-head-commit", head, "--delete-branch"])
    state.stage("registry", "auto_arm_returned")
    view = json.loads(command(["gh", "pr", "view", url, "--repo", TAP_REPO,
                               "--json", "url,headRefOid,autoMergeRequest"]))
    if view.get("url") != url or view.get("headRefOid") != head or not view.get("autoMergeRequest"):
        raise Refused("registry exact PR auto-merge readback refused")
    state.stage("registry", "auto_arm_verified", complete=True)
    return url
