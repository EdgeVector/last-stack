#!/usr/bin/env python3
"""Fixture-only tests for the GitHub artifact publish path (no network).

Covers bin/last-stack-github-artifact-build (runner side) and
bin/last-stack-github-artifact-pull (Mac side) against a fake `gh` and a fake
`lastgit artifact`. Every refusal case also asserts the real CAS stayed empty.
Brain: design-github-artifact-publish-path
"""
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BUILD = os.path.join(ROOT, "bin", "last-stack-github-artifact-build")
PULL = os.path.join(ROOT, "bin", "last-stack-github-artifact-pull")
FIX = os.path.join(ROOT, "tests", "fixtures", "github-artifact")
REPO = "EdgeVector/remote"
BASE = "https://x.invalid"  # never contacted; documents that no network is used


def run(cmd, cwd=None, env=None):
    return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True)


def git(repo, *args):
    r = run(["git", "-C", repo] + list(args))
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def make_repo(d):
    repo = os.path.join(d, "src-repo")
    os.makedirs(os.path.join(repo, "bin"))
    os.makedirs(os.path.join(repo, "src"))
    os.makedirs(os.path.join(repo, ".lastgit"))
    for rel, body, mode in [
        ("AGENTS.md", "agents\n", 0o644), ("README.md", "readme\n", 0o644),
        ("bin/ra", "#!/bin/sh\necho ra\n", 0o755), ("src/cli.ts", "export {}\n", 0o644),
    ]:
        p = os.path.join(repo, rel)
        with open(p, "w") as fh:
            fh.write(body)
        os.chmod(p, mode)
    with open(os.path.join(repo, ".lastgit", "artifacts.json"), "w") as fh:
        json.dump({"artifacts": [{"app": "remote", "platform": "darwin-arm64",
                                   "paths": ["AGENTS.md", "README.md", "bin", "src"]}]}, fh)
    git(repo, "init", "-q", "-b", "main")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "add", "-A")
    git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init")
    return repo


def zip_dir(out):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for d, _s, files in os.walk(out):  # walk-ok: test fixture dir
            for f in files:
                full = os.path.join(d, f)
                zf.write(full, os.path.relpath(full, out))
    return buf.getvalue()


class Base(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.d = self._td.name
        self.addCleanup(self._td.cleanup)
        self.repo = make_repo(self.d)
        self.oid = git(self.repo, "rev-parse", "HEAD")
        self.tree = git(self.repo, "rev-parse", "HEAD^{tree}")
        self.out = os.path.join(self.d, "out")
        r = run([sys.executable, BUILD, "--repo", REPO, "--root", self.repo, "--out", self.out])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.cas = os.path.join(self.d, "cas")
        self.log = os.path.join(self.d, "gh.log")
        self.routes_path = os.path.join(self.d, "routes.json")
        self.set_routes()

    def set_routes(self, zip_bytes=None, check=None, run_over=None, tip=None, art_over=None, digest=True, tree=None):
        zb = zip_bytes if zip_bytes is not None else zip_dir(self.out)
        zpath = os.path.join(self.d, "a.zip")
        with open(zpath, "wb") as fh:
            fh.write(zb)
        oid = self.oid
        art = {"id": 5, "name": "ht-artifact-" + oid, "expired": False, "created_at": "2026-09-30T00:00:00Z",
               "workflow_run": {"id": 77, "head_branch": "main", "head_sha": oid}}
        if digest:
            art["digest"] = "sha256:" + hashlib.sha256(zb).hexdigest()
        art.update(art_over or {})
        runj = {"id": 77, "status": "completed", "conclusion": "success", "event": "push", "head_branch": "main",
                "head_sha": oid, "repository": {"full_name": REPO}, "head_repository": {"full_name": REPO}}
        runj.update(run_over or {})
        chk = check if check is not None else [{"name": "ci-required", "status": "completed", "conclusion": "success"}]
        ref = "repos/%s/git/ref/heads/main" % REPO
        routes = {
            ref: {"json": {"object": {"sha": tip or oid}}},
            "repos/%s/commits/%s/check-runs?per_page=100&check_name=ci-required" % (REPO, oid): {"json": {"check_runs": chk}},
            "repos/%s/actions/artifacts?name=ht-artifact-%s&per_page=30" % (REPO, oid): {"json": {"artifacts": [art]}},
            "repos/%s/actions/runs/77" % REPO: {"json": runj},
            "repos/%s/actions/artifacts/5/zip" % REPO: {"file": zpath},
            "repos/%s/git/commits/%s" % (REPO, oid): {"json": {"tree": {"sha": tree or self.tree}}},
        }
        with open(self.routes_path, "w") as fh:
            json.dump(routes, fh)

    def pull(self, *extra, situations="/usr/bin/true"):
        env = dict(os.environ)
        env.update({"LAST_STACK_GH": os.path.join(FIX, "fake-gh"), "LAST_STACK_LASTGIT": os.path.join(FIX, "fake-lastgit"),
                    "FAKE_GH_ROUTES": self.routes_path, "FAKE_GH_LOG": self.log, "LAST_STACK_SITUATIONS_BIN": situations})
        cmd = [sys.executable, PULL, "--app", "remote", "--repo", REPO, "--root", self.cas, "--json"] + list(extra)
        r = run(cmd, env=env)
        try:
            res = json.loads(r.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            res = {}
        return r.returncode, res, r.stderr

    def assertCasUntouched(self):
        self.assertFalse(os.path.exists(self.cas) and os.listdir(self.cas), "CAS was written: %s" % (
            os.listdir(self.cas) if os.path.exists(self.cas) else ""))

    def rebuild_zip_with(self, mutate):
        """Rewrite bundle.tar / provenance.json in self.out via mutate(tar_members, prov) and re-zip."""
        app = os.path.join(self.out, "remote")
        with open(os.path.join(app, "provenance.json")) as fh:
            prov = json.load(fh)
        with tarfile.open(os.path.join(app, "bundle.tar")) as tar:
            members = [(m, tar.extractfile(m).read() if m.isreg() else b"") for m in tar.getmembers()]
        members, prov = mutate(members, prov)
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
            for m, data in members:
                tar.addfile(m, io.BytesIO(data) if m.isreg() else None)
        tar_bytes = buf.getvalue()
        prov["tar_sha256"] = hashlib.sha256(tar_bytes).hexdigest()
        with open(os.path.join(app, "bundle.tar"), "wb") as fh:
            fh.write(tar_bytes)
        with open(os.path.join(app, "provenance.json"), "w") as fh:
            json.dump(prov, fh)
        self.set_routes()


    # A plausible oid that is NEWER than the fixture commit, for seeding a channel
    # the promote under test must be ordered against.
    NEWER = "f" * 40

    def seed_channel(self, head):
        d = os.path.join(self.cas, "channels", "remote")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "stable.json"), "w") as fh:
            json.dump({"source_oid": head, "manifest_digest": "d" * 64, "files": []}, fh)

    def head_now(self):
        with open(os.path.join(self.cas, "channels", "remote", "stable.json")) as fh:
            return json.load(fh)["source_oid"]

    def add_compare(self, base, head, status):
        with open(self.routes_path) as fh:
            routes = json.load(fh)
        routes["repos/%s/compare/%s...%s" % (REPO, base, head)] = {"json": {"status": status}}
        with open(self.routes_path, "w") as fh:
            json.dump(routes, fh)

    def chan(self):
        return json.load(open(os.path.join(self.cas, "channels", "remote", "stable.json")))

    def sign_pull(self, *extra, env=None):
        for k in ("FAKE_CODESIGN_FAIL", "FAKE_SECURITY_NONE", "FAKE_SECURITY_TWO"):
            os.environ.pop(k, None)
        os.environ.update(env or {})
        self.addCleanup(lambda: [os.environ.pop(k, None) for k in (env or {})])
        return self.pull("--sign", "bin/ra=com.test.ra", "--codesign", os.path.join(FIX, "fake-codesign"),
                         "--security", os.path.join(FIX, "fake-security"), *extra)

    def unsigned_promote(self):
        rc, res, err = self.pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        return res

class BuilderTests(Base):
    def test_provenance_and_modes(self):
        with open(os.path.join(self.out, "remote", "provenance.json")) as fh:
            prov = json.load(fh)
        self.assertEqual(prov["source_oid"], self.oid)
        self.assertEqual(prov["tree_oid"], self.tree)
        self.assertEqual(prov["platform"], "darwin-arm64")
        self.assertEqual(prov["repo"], REPO)
        files = {f["path"]: f for f in prov["files"]}
        self.assertEqual(sorted(files), ["AGENTS.md", "README.md", "bin/ra", "src/cli.ts"])
        self.assertEqual(files["bin/ra"]["mode"], 0o755)
        self.assertEqual(files["AGENTS.md"]["mode"], 0o644)
        with tarfile.open(os.path.join(self.out, "remote", "bundle.tar")) as tar:
            self.assertEqual(sorted(m.name for m in tar.getmembers()), sorted(files))
            self.assertEqual(tar.getmember("bin/ra").mode & 0o777, 0o755)

    def test_refuses_symlink_escape_and_missing(self):
        os.symlink("/etc/hosts", os.path.join(self.repo, "src", "link"))
        r = run([sys.executable, BUILD, "--repo", REPO, "--root", self.repo, "--out", self.out + "2", "--oid", self.oid])
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("symlink", r.stderr)
        os.unlink(os.path.join(self.repo, "src", "link"))
        cfg = os.path.join(self.repo, ".lastgit", "artifacts.json")
        for bad in (["../x"], ["/etc"], ["nope"]):
            with open(cfg, "w") as fh:
                json.dump({"artifacts": [{"app": "remote", "paths": bad}]}, fh)
            r = run([sys.executable, BUILD, "--repo", REPO, "--root", self.repo, "--out", self.out + "3", "--oid", self.oid])
            self.assertNotEqual(r.returncode, 0, bad)


class PullTests(Base):
    def test_promotes_verified_artifact(self):
        rc, res, err = self.pull()
        self.assertEqual(rc, 0, err)
        self.assertEqual(res["status"], "promoted")
        chan = json.load(open(os.path.join(self.cas, "channels", "remote", "stable.json")))
        self.assertEqual(chan["source_oid"], self.oid)
        self.assertEqual(chan["manifest_digest"], res["manifest_digest"])
        self.assertTrue(os.path.exists(os.path.join(self.cas, "builds", "remote", self.oid, "darwin-arm64.json")))
        blob = [f for f in chan["files"] if f["path"] == "bin/ra"][0]
        self.assertEqual(blob["mode"], 0o755)
        # Same-head pulls still verify the real artifact and emit full provenance.
        open(self.log, "w").close()
        rc, res, _ = self.pull()
        self.assertEqual((rc, res["status"]), (0, "promoted"))
        self.assertEqual((res["run_id"], res["artifact_id"]), (77, 5))
        self.assertIn("/zip", open(self.log).read())

    def test_dry_run_writes_nothing(self):
        rc, res, err = self.pull("--dry-run")
        self.assertEqual((rc, res.get("status")), (0, "dry-run-verified"), err)
        self.assertCasUntouched()

    def test_holds_until_green_and_published(self):
        self.set_routes(check=[])
        rc, res, _ = self.pull()
        self.assertEqual((rc, res["status"]), (3, "hold"))
        self.set_routes(check=[{"name": "ci-required", "status": "in_progress", "conclusion": None}])
        self.assertEqual(self.pull()[0], 3)
        self.set_routes(art_over={"expired": True})
        self.assertEqual(self.pull()[0], 3)
        self.set_routes(run_over={"status": "in_progress", "conclusion": None})
        self.assertEqual(self.pull()[0], 3)
        self.assertCasUntouched()

    def test_platform_mismatch_holds(self):
        rc, res, _ = self.pull("--platform", "linux-x64")
        self.assertEqual((rc, res["status"]), (3, "hold"))
        self.assertCasUntouched()

    def test_refuses_and_leaves_cas_untouched(self):
        cases = {
            "red gate": dict(check=[{"name": "ci-required", "status": "completed", "conclusion": "failure"}]),
            "pull_request run": dict(run_over={"event": "pull_request"}),
            "other branch run": dict(run_over={"head_branch": "evil"}),
            "run for other commit": dict(run_over={"head_sha": "0" * 40}),
            "fork head": dict(run_over={"head_repository": {"full_name": "someone/remote"}}),
            "failed run": dict(run_over={"conclusion": "failure"}),
            "no digest": dict(digest=False),
            "wrong tree": dict(tree="1" * 40),
            "moved tip": dict(tip="2" * 40),
        }
        for label, kw in cases.items():
            self.set_routes(**kw)
            rc, res, err = self.pull()
            self.assertEqual(rc, 1, "%s: %s %s" % (label, res, err))
            self.assertEqual(res["status"], "failed", label)
            self.assertCasUntouched()

    def test_zip_digest_mismatch(self):
        self.set_routes()
        routes = json.load(open(self.routes_path))
        key = "repos/%s/actions/artifacts?name=ht-artifact-%s&per_page=30" % (REPO, self.oid)
        routes[key]["json"]["artifacts"][0]["digest"] = "sha256:" + "0" * 64
        json.dump(routes, open(self.routes_path, "w"))
        rc, res, _ = self.pull()
        self.assertEqual(rc, 1)
        self.assertIn("digest", res["reason"])
        self.assertCasUntouched()

    def test_tampered_bundle_file(self):
        def mutate(members, prov):
            out = []
            for m, data in members:
                out.append((m, b"X" * len(data) if m.name == "bin/ra" else data))
            return out, prov
        self.rebuild_zip_with(mutate)
        rc, res, _ = self.pull()
        self.assertEqual(rc, 1)
        self.assertIn("mismatch", res["reason"])
        self.assertCasUntouched()

    def test_extra_and_missing_files(self):
        def extra(members, prov):
            ti = tarfile.TarInfo("src/extra.ts")
            ti.size = 3
            return members + [(ti, b"abc")], prov
        self.rebuild_zip_with(extra)
        self.assertEqual(self.pull()[0], 1)
        self.assertCasUntouched()

    def test_link_and_escape_members(self):
        def link(members, prov):
            ti = tarfile.TarInfo("src/l")
            ti.type = tarfile.SYMTYPE
            ti.linkname = "/etc/passwd"
            return members + [(ti, b"")], prov
        self.rebuild_zip_with(link)
        self.assertEqual(self.pull()[0], 1)

        def escape(members, prov):
            ti = tarfile.TarInfo("../evil")
            ti.size = 1
            return members + [(ti, b"x")], prov
        self.rebuild_zip_with(escape)
        rc, res, _ = self.pull()
        self.assertEqual(rc, 1)
        self.assertCasUntouched()

    def test_provenance_lies(self):
        def lie(members, prov):
            prov["source_oid"] = "3" * 40
            return members, prov
        self.rebuild_zip_with(lie)
        self.assertEqual(self.pull()[0], 1)
        self.assertCasUntouched()

    def test_situations_block_stops_before_network(self):
        rc, res, _ = self.pull(situations="/usr/bin/false")
        self.assertEqual(rc, 1)
        self.assertIn("situations", res["reason"])
        self.assertCasUntouched()
        self.assertFalse(os.path.exists(self.log) and open(self.log).read().strip())

    def test_non_tip_needs_flag(self):
        self.set_routes(tip="2" * 40)
        self.assertEqual(self.pull()[0], 1)
        rc, res, err = self.pull("--oid", self.oid, "--allow-non-tip")
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)


class SignTests(Base):
    def test_signs_and_manifest_uses_signed_bytes(self):
        rc, res, err = self.sign_pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        with open(os.path.join(self.out, "remote", "provenance.json")) as fh:
            prov = {f["path"]: f for f in json.load(fh)["files"]}
        self.assertEqual(res["signed"]["bin/ra"]["pre_sign_sha256"], prov["bin/ra"]["sha256"])
        chan = json.load(open(os.path.join(self.cas, "channels", "remote", "stable.json")))
        got = {f["path"]: f for f in chan["files"]}
        self.assertNotEqual(got["bin/ra"]["sha256"], prov["bin/ra"]["sha256"])
        self.assertEqual(got["bin/ra"]["mode"], 0o755)
        self.assertEqual(got["README.md"]["sha256"], prov["README.md"]["sha256"])
        blob = os.path.join(self.cas, "blobs", "sha256", got["bin/ra"]["sha256"][:2], got["bin/ra"]["sha256"])
        self.assertIn(b"SIGNED:com.test.ra:AAAA", open(blob, "rb").read())

    def test_no_identity_fails_closed(self):
        rc, res, _ = self.sign_pull(env={"FAKE_SECURITY_NONE": "1"})
        self.assertEqual(rc, 1)
        self.assertIn("identity", res["reason"])
        self.assertCasUntouched()

    def test_ambiguous_identity_fails(self):
        rc, res, _ = self.sign_pull(env={"FAKE_SECURITY_TWO": "1"})
        self.assertEqual(rc, 1)
        self.assertIn("exactly one", res["reason"])
        self.assertCasUntouched()

    def test_codesign_failure_fails_closed(self):
        rc, res, _ = self.sign_pull(env={"FAKE_CODESIGN_FAIL": "1"})
        self.assertEqual(rc, 1)
        self.assertIn("codesign", res["reason"])
        self.assertCasUntouched()

    def test_missing_sign_target_fails(self):
        rc, res, _ = self.pull("--sign", "bin/none=x", "--security", os.path.join(FIX, "fake-security"),
                               "--codesign", os.path.join(FIX, "fake-codesign"))
        self.assertEqual(rc, 1)
        self.assertIn("not in the bundle", res["reason"])
        self.assertCasUntouched()

    def test_current_but_unsigned_resigns_same_oid(self):
        old = self.unsigned_promote()
        rc, res, err = self.sign_pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(res["oid"], old["oid"])
        self.assertNotEqual(res["manifest_digest"], old["manifest_digest"])
        self.assertIn("bin/ra", res["signed"])
        got = {f["path"]: f for f in self.chan()["files"]}
        blob = os.path.join(self.cas, "blobs", "sha256", got["bin/ra"]["sha256"][:2], got["bin/ra"]["sha256"])
        self.assertIn(b"SIGNED:com.test.ra:AAAA", open(blob, "rb").read())

    def test_current_but_unsigned_dry_run_reports_and_writes_nothing(self):
        old = self.unsigned_promote()
        before = open(os.path.join(self.cas, "channels", "remote", "stable.json")).read()
        rc, res, err = self.sign_pull("--dry-run")
        self.assertEqual((rc, res.get("status")), (0, "dry-run-verified"), err)
        self.assertEqual(open(os.path.join(self.cas, "channels", "remote", "stable.json")).read(), before)
        self.assertEqual(self.chan()["manifest_digest"], old["manifest_digest"])

    def test_current_and_signed_is_noop(self):
        rc, res, err = self.sign_pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        open(self.log, "w").close()
        rc, res, err = self.sign_pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertIn("/zip", open(self.log).read())

    def test_current_but_unsigned_no_identity_fails_closed(self):
        old = self.unsigned_promote()
        rc, res, _ = self.sign_pull(env={"FAKE_SECURITY_NONE": "1"})
        self.assertEqual(rc, 1)
        self.assertIn("identity", res["reason"])
        self.assertEqual(self.chan()["manifest_digest"], old["manifest_digest"])

    def test_current_but_unsigned_codesign_failure_fails_closed(self):
        old = self.unsigned_promote()
        rc, res, _ = self.sign_pull(env={"FAKE_CODESIGN_FAIL": "1"})
        self.assertEqual(rc, 1)
        self.assertEqual(self.chan()["manifest_digest"], old["manifest_digest"])

    def test_unsigned_app_without_sign_spec_stays_current(self):
        self.unsigned_promote()
        rc, res, _ = self.pull()
        self.assertEqual((rc, res["status"]), (0, "promoted"))

    def test_routines_default_sign_table(self):
        sys.path.insert(0, os.path.join(ROOT, "bin"))
        import importlib.machinery, importlib.util
        loader = importlib.machinery.SourceFileLoader("pull_mod", PULL)
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("pull_mod", loader))
        loader.exec_module(mod)
        self.assertEqual(mod.SIGN_DEFAULTS["routines"], [("dist/routines", "com.edgevector.routines")])


class ChannelOrderTests(Base):
    """A promote must never move the channel to an ancestor of its own head.

    host-track stages a version tree and parks a canary from the channel file
    alone, and no reader downstream of it checks commit order, so a backward
    channel write installs an older build while every surface reports success.
    Brain: papercut-host-track-stages-a-canary-binary-that-is-not-the-artifact-it-promoted-20261001
    """

    def test_refuses_backward_channel_move(self):
        self.seed_channel(self.NEWER)
        self.add_compare(self.NEWER, self.oid, "behind")
        rc, res, err = self.pull()
        self.assertEqual(rc, 1, err)
        self.assertEqual(res.get("status"), "failed")
        self.assertIn("BACKWARD", res.get("reason", ""))
        # The channel still names the newer head and nothing was downloaded.
        self.assertEqual(self.head_now(), self.NEWER)
        self.assertNotIn("/zip", open(self.log).read())

    def test_refuses_diverged_channel_move(self):
        self.seed_channel(self.NEWER)
        self.add_compare(self.NEWER, self.oid, "diverged")
        rc, res, err = self.pull()
        self.assertEqual(rc, 1, err)
        self.assertIn("BACKWARD", res.get("reason", ""))
        self.assertEqual(self.head_now(), self.NEWER)

    def test_allow_rollback_permits_the_backward_move(self):
        self.seed_channel(self.NEWER)
        self.add_compare(self.NEWER, self.oid, "behind")
        rc, res, err = self.pull("--allow-rollback")
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(self.head_now(), self.oid)

    def test_allow_non_tip_alone_does_not_permit_it(self):
        """The 2026-10-01 regression was produced BY an --allow-non-tip run."""
        self.seed_channel(self.NEWER)
        self.add_compare(self.NEWER, self.oid, "behind")
        rc, res, err = self.pull("--allow-non-tip", "--oid", self.oid)
        self.assertEqual(rc, 1, err)
        self.assertIn("BACKWARD", res.get("reason", ""))
        self.assertEqual(self.head_now(), self.NEWER)

    def test_forward_move_still_promotes(self):
        self.seed_channel(self.NEWER)
        self.add_compare(self.NEWER, self.oid, "ahead")
        rc, res, err = self.pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(self.head_now(), self.oid)

    def test_unorderable_head_is_allowed_and_logged(self):
        """A head GitHub cannot resolve (force-pushed away) must not freeze the channel."""
        self.seed_channel(self.NEWER)  # no compare route -> fake-gh answers HTTP 404
        rc, res, err = self.pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(self.head_now(), self.oid)
        self.assertIn("cannot order", err)


class ChannelOrderRecordTests(Base):
    """The channel file must RECORD the order verdict and the head it displaced.

    `host-track status` holds no git object store, so the direction of a promote
    is knowable only at the moment of the write. Without it a regression renders
    as `main_unpublished=true` -- the same word as ordinary publish lag, and the
    one reading under which an operator does nothing.
    Brain: papercut-host-track-main-unpublished-cannot-tell-publish-lag-from-a-channel-regression-20261001
    """

    def test_initial_promote_records_initial_and_no_previous(self):
        rc, res, err = self.pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(self.chan()["promote_order"], "initial")
        self.assertIsNone(self.chan()["previous_source_oid"])
        self.assertEqual(res["promote_order"], "initial")

    def test_forward_promote_records_forward_and_the_displaced_head(self):
        self.seed_channel(self.NEWER)
        self.add_compare(self.NEWER, self.oid, "ahead")
        rc, res, err = self.pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(self.chan()["promote_order"], "forward")
        self.assertEqual(self.chan()["previous_source_oid"], self.NEWER)

    def test_allowed_rollback_records_backward_not_forward(self):
        """The case the whole field exists for.

        `--allow-rollback` short-circuited the order check before this change, so
        a deliberate backward promote wrote a channel file indistinguishable from
        a forward one. The verdict must be computed even when the refusal is
        bypassed -- a legal backward move is still a backward move.
        """
        self.seed_channel(self.NEWER)
        self.add_compare(self.NEWER, self.oid, "behind")
        rc, res, err = self.pull("--allow-rollback")
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(self.chan()["promote_order"], "backward")
        self.assertEqual(self.chan()["previous_source_oid"], self.NEWER)
        self.assertEqual(res["promote_order"], "backward")

    def test_diverged_rollback_records_backward(self):
        self.seed_channel(self.NEWER)
        self.add_compare(self.NEWER, self.oid, "diverged")
        rc, res, err = self.pull("--allow-rollback")
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(self.chan()["promote_order"], "backward")

    def test_unorderable_promote_records_unordered_not_forward(self):
        """`unordered` is not `forward`: nobody established the direction."""
        self.seed_channel(self.NEWER)  # no compare route -> fake-gh answers HTTP 404
        rc, res, err = self.pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(self.chan()["promote_order"], "unordered")
        self.assertEqual(self.chan()["previous_source_oid"], self.NEWER)

    def test_resign_of_the_same_oid_records_resign(self):
        """A re-sign promotes the oid the channel already names; that is not a move."""
        self.unsigned_promote()
        rc, res, err = self.sign_pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        self.assertEqual(self.chan()["promote_order"], "resign")
        self.assertEqual(self.chan()["previous_source_oid"], self.oid)

    def test_cas_manifest_is_not_modified(self):
        """Only the channel COPY grows fields. The CAS manifest stays canonical."""
        rc, res, err = self.pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        man = json.load(open(os.path.join(self.cas, "manifests", res["manifest_digest"] + ".json")))
        self.assertNotIn("promote_order", man)
        self.assertNotIn("previous_source_oid", man)
        # and the channel file still carries everything a manifest reader needs
        for key in ("source_oid", "manifest_digest", "app", "platform", "files"):
            self.assertIn(key, self.chan(), key)

    def test_dry_run_reports_the_order_without_writing(self):
        self.seed_channel(self.NEWER)
        self.add_compare(self.NEWER, self.oid, "behind")
        rc, res, err = self.pull("--allow-rollback", "--dry-run")
        self.assertEqual((rc, res.get("status")), (0, "dry-run-verified"), err)
        self.assertEqual(res["promote_order"], "backward")
        self.assertEqual(self.head_now(), self.NEWER)


class CanonicalReuseTests(Base):
    def setUp(self):
        super().setUp()
        self.artifact_log = os.path.join(self.d, "artifact.log")
        for key, value in {"FAKE_ARTIFACT_LOG": self.artifact_log,
                           "FAKE_ARTIFACT_CREATED_AT": "2026-10-09T00:00:00.000Z"}.items():
            previous = os.environ.get(key)
            os.environ[key] = value
            self.addCleanup(lambda k=key, v=previous: os.environ.pop(k, None) if v is None else os.environ.__setitem__(k,v))

    def snapshot(self):
        result = {}
        for d, _dirs, files in os.walk(self.cas):  # walk-ok: private fixture CAS
            for name in files:
                path = Path(d) / name
                info = path.lstat()
                result[os.path.relpath(path,self.cas)] = (info.st_mode,
                    path.read_bytes() if stat.S_ISREG(info.st_mode) else os.readlink(path) if path.is_symlink() else None)
        return result

    def events(self):
        return [json.loads(line) for line in Path(self.artifact_log).read_text().splitlines()]

    def canonical(self):
        return os.path.join(self.cas,"builds","remote",self.oid,"darwin-arm64.json")

    def seed(self):
        rc,res,err=self.pull("--channel","candidate")
        self.assertEqual((rc,res.get("status")),(0,"promoted"),err)
        return res

    def rewrite(self, mutate):
        with open(self.canonical()) as fh: man=json.load(fh)
        mutate(man)
        body={k:v for k,v in man.items() if k!="manifest_digest"}
        body["files"]=sorted(body["files"],key=lambda f:f["path"])
        man["manifest_digest"]=hashlib.sha256(json.dumps(body,sort_keys=True).encode()).hexdigest()
        encoded=json.dumps(man).encode()
        for path in [self.canonical(),os.path.join(self.cas,"manifests",man["manifest_digest"]+".json")]:
            with open(path,"wb") as fh: fh.write(encoded)
        return man

    def test_distinct_clock_cross_channel_reuses_canonical(self):
        first=self.seed()
        canonical=Path(self.canonical()).read_bytes()
        os.environ["FAKE_ARTIFACT_CREATED_AT"]="2026-10-09T01:00:00.000Z"
        rc,res,err=self.pull()
        self.assertEqual(Path(self.canonical()).read_bytes(),canonical,"canonical build bytes remain immutable")
        self.assertEqual(len([e for e in self.events() if e["verb"]=="publish"]),1,"one publish for identical payload")
        self.assertEqual((rc,res.get("status"),res.get("manifest_digest")),(0,"promoted",first["manifest_digest"]),err)
        self.assertEqual((res["tree_oid"],res["run_id"],res["artifact_id"]),(self.tree,77,5))

    def test_same_head_returns_complete_checked_provenance(self):
        first=self.seed()
        rc,res,err=self.pull("--channel","candidate")
        self.assertEqual((rc,res.get("status"),res.get("manifest_digest")),(0,"promoted",first["manifest_digest"]),"complete checked promoted receipt: "+err)
        self.assertEqual((res["tree_oid"],res["platform"],res["run_id"],res["artifact_id"]),(self.tree,"darwin-arm64",77,5))
        self.assertIn("/zip",Path(self.log).read_text())

    def test_same_head_failed_ci_has_zero_effects(self):
        self.seed(); before=self.snapshot()
        self.set_routes(check=[{"name":"ci-required","status":"completed","conclusion":"failure"}])
        rc,res,err=self.pull("--channel","candidate")
        self.assertEqual(self.snapshot(),before,"same-head failed CI has zero publication")
        self.assertNotEqual(rc,0,"same-head failed CI refuses")
        self.assertIn("not green",res.get("reason",""))

    def assert_bad_canonical(self, field, value):
        self.seed()
        self.rewrite(lambda man:man.__setitem__(field,value))
        before=self.snapshot()
        rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"wrong canonical "+field+" has zero publication")
        self.assertNotEqual(rc,0,"wrong canonical "+field+" refuses")
        self.assertIn("canonical",res.get("reason",""))

    def test_wrong_canonical_app(self): self.assert_bad_canonical("app","other")
    def test_wrong_canonical_repo(self): self.assert_bad_canonical("repo","other")
    def test_wrong_canonical_source(self): self.assert_bad_canonical("source_oid","e"*40)
    def test_wrong_canonical_platform(self): self.assert_bad_canonical("platform","other-arm64")

    def assert_bad_tuple(self, field, value):
        self.seed()
        self.rewrite(lambda man:man["files"][0].__setitem__(field,value))
        before=self.snapshot()
        rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"wrong canonical tuple "+field+" has zero publication")
        self.assertNotEqual(rc,0,"wrong canonical tuple "+field+" refuses")
        self.assertIn("canonical",res.get("reason",""))

    def test_wrong_canonical_path(self): self.assert_bad_tuple("path","other-file")
    def test_wrong_canonical_size(self): self.assert_bad_tuple("size",123456)
    def test_wrong_canonical_mode(self): self.assert_bad_tuple("mode",0o600)

    def test_wrong_canonical_sha(self):
        self.seed()
        data=b"different but valid canonical blob"
        digest=hashlib.sha256(data).hexdigest()
        path=os.path.join(self.cas,"blobs","sha256",digest[:2],digest)
        os.makedirs(os.path.dirname(path),exist_ok=True)
        with open(path,"wb") as fh:fh.write(data)
        self.rewrite(lambda man:man["files"][0].update(sha256=digest,size=len(data)))
        before=self.snapshot();rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"wrong canonical sha has zero publication")
        self.assertNotEqual(rc,0,"wrong canonical sha refuses")

    def test_canonical_verify_failure_has_zero_effects(self):
        first=self.seed()
        man=json.loads(Path(self.canonical()).read_text())
        path=os.path.join(self.cas,"blobs","sha256",man["files"][0]["sha256"][:2],man["files"][0]["sha256"])
        with open(path,"wb") as fh:fh.write(b"corrupt canonical blob")
        before=self.snapshot();rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"failed public canonical verify has zero publication")
        self.assertNotEqual(rc,0,"failed public canonical verify refuses")
        self.assertIn("verify",res.get("reason",""))


    def test_wrong_canonical_schema(self): self.assert_bad_canonical("schema_version",2)
    def test_wrong_canonical_schema_type(self): self.assert_bad_canonical("schema_version",True)
    def test_wrong_canonical_digest(self):
        self.seed();path=Path(self.canonical());man=json.loads(path.read_text())
        man["manifest_digest"]="z"*64;path.write_text(json.dumps(man))
        before=self.snapshot();rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"wrong canonical digest has zero publication")
        self.assertNotEqual(rc,0,"wrong canonical digest refuses")
        self.assertIn("digest is malformed",res.get("reason",""))
    def test_malformed_canonical_files(self): self.assert_bad_canonical("files",{})

    def assert_malformed(self, mutate, reason):
        self.seed();self.rewrite(mutate);before=self.snapshot()
        rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"malformed canonical "+reason+" has zero publication")
        self.assertNotEqual(rc,0,"malformed canonical "+reason+" refuses")

    def test_missing_canonical_tuple_field(self):
        self.assert_malformed(lambda man:man["files"][0].pop("mode"),"tuple-field")
    def test_malformed_canonical_tuple_size_type(self):
        self.assert_malformed(lambda man:man["files"][0].__setitem__("size",True),"size-type")
    def test_malformed_canonical_tuple_mode_type(self):
        self.assert_malformed(lambda man:man["files"][0].__setitem__("mode",True),"mode-type")
    def test_malformed_canonical_tuple_digest(self):
        self.assert_malformed(lambda man:man["files"][0].__setitem__("sha256","z"*64),"digest-format")
    def test_duplicate_canonical_path(self):
        self.assert_malformed(lambda man:man["files"].append(dict(man["files"][0])),"duplicate-path")
    def test_unsafe_canonical_path(self):
        self.assert_malformed(lambda man:man["files"][0].__setitem__("path","../escape"),"unsafe-path")

    def test_canonical_build_manifest_disagree(self):
        self.seed()
        path=Path(self.canonical());man=json.loads(path.read_text())
        man["created_at"]="2026-10-09T02:00:00Z";path.write_text(json.dumps(man))
        before=self.snapshot();rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"canonical build disagreement has zero publication")
        self.assertNotEqual(rc,0,"canonical build disagreement refuses")
        self.assertIn("disagree",res.get("reason",""))

    def test_duplicate_canonical_json_key(self):
        self.seed();path=Path(self.canonical())
        body=path.read_text();path.write_text(body.replace('"app": "remote"','"app": "other", "app": "remote"',1))
        before=self.snapshot();rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"duplicate canonical JSON key has zero publication")
        self.assertNotEqual(rc,0,"duplicate canonical JSON key refuses")

    def test_symlink_canonical_build(self):
        self.seed();path=Path(self.canonical());saved=Path(self.d)/"saved-build.json"
        path.rename(saved);path.symlink_to(saved)
        before=self.snapshot();rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"canonical symlink has zero publication")
        self.assertNotEqual(rc,0,"canonical symlink refuses")

    def test_fifo_canonical_build_refuses_promptly(self):
        self.seed();path=Path(self.canonical());path.unlink();os.mkfifo(path)
        before=self.snapshot()
        env=dict(os.environ);env.update({"LAST_STACK_GH":os.path.join(FIX,"fake-gh"),"LAST_STACK_LASTGIT":os.path.join(FIX,"fake-lastgit"),"FAKE_GH_ROUTES":self.routes_path,"FAKE_GH_LOG":self.log,"LAST_STACK_SITUATIONS_BIN":"/usr/bin/true"})
        try:
            result=subprocess.run([sys.executable,PULL,"--app","remote","--repo",REPO,"--root",self.cas,"--json"],env=env,capture_output=True,text=True,timeout=3)
        except subprocess.TimeoutExpired:
            self.fail("canonical FIFO refuses promptly without a writer")
        self.assertEqual(self.snapshot(),before,"canonical FIFO has zero publication")
        self.assertNotEqual(result.returncode,0,"canonical FIFO refuses")

    def test_oversize_canonical_build(self):
        self.seed();self.rewrite(lambda man:man.__setitem__("padding","x"*(8*1024*1024)))
        before=self.snapshot();rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"canonical byte cap has zero publication")
        self.assertNotEqual(rc,0,"canonical byte cap refuses")

    def test_missing_canonical_manifest(self):
        first=self.seed();Path(self.cas,"manifests",first["manifest_digest"]+".json").unlink()
        before=self.snapshot();rc,res,err=self.pull()
        self.assertEqual(self.snapshot(),before,"missing canonical manifest has zero publication")
        self.assertNotEqual(rc,0,"missing canonical manifest refuses")

    def test_same_head_run_provenance_has_zero_effects(self):
        self.seed();before=self.snapshot();self.set_routes(run_over={"event":"pull_request"})
        rc,res,err=self.pull("--channel","candidate")
        self.assertEqual(self.snapshot(),before,"same-head wrong run has zero publication")
        self.assertNotEqual(rc,0,"same-head wrong run refuses")
        self.assertIn("push run",res.get("reason",""))

    def test_signed_derivative_mismatch_still_publishes(self):
        first=self.seed();rc,res,err=self.sign_pull()
        self.assertEqual((rc,res.get("status")),(0,"promoted"),err)
        self.assertNotEqual(res["manifest_digest"],first["manifest_digest"])
        self.assertEqual(len([e for e in self.events() if e["verb"]=="publish"]),2)


    def text_pull(self, *extra):
        env=dict(os.environ);env.update({"LAST_STACK_GH":os.path.join(FIX,"fake-gh"),"LAST_STACK_LASTGIT":os.path.join(FIX,"fake-lastgit"),"FAKE_GH_ROUTES":self.routes_path,"FAKE_GH_LOG":self.log,"LAST_STACK_SITUATIONS_BIN":"/usr/bin/true"})
        return subprocess.run([sys.executable,PULL,"--app","remote","--repo",REPO,"--root",self.cas,"--channel","candidate",*extra],env=env,capture_output=True,text=True,timeout=15)

    def test_text_same_head_keeps_fast_no_zip_status(self):
        self.seed();before=self.snapshot();Path(self.log).write_text("")
        r=self.text_pull()
        self.assertNotIn("/zip",Path(self.log).read_text(),"ordinary text same-head performs zero ZIP downloads")
        self.assertNotIn("check-runs",Path(self.log).read_text(),"ordinary text status does not claim new CI authority")
        self.assertEqual(self.snapshot(),before,"ordinary text same-head performs zero publication")
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(r.stdout.startswith("current app=remote repo="),"ordinary text current stays status only")
        self.assertNotIn("manifest_digest",r.stdout)

    def test_text_same_head_signed_keeps_signature_check(self):
        flags=["--sign","bin/ra=com.test.ra","--codesign",os.path.join(FIX,"fake-codesign"),"--security",os.path.join(FIX,"fake-security")]
        rc,res,err=self.sign_pull("--channel","candidate")
        self.assertEqual((rc,res.get("status")),(0,"promoted"),err)
        Path(self.log).write_text("");before=self.snapshot();r=self.text_pull(*flags)
        self.assertNotIn("/zip",Path(self.log).read_text(),"signed ordinary text same-head performs zero ZIP downloads")
        self.assertEqual(self.snapshot(),before,"signed ordinary text has zero publication")
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(r.stdout.startswith("current app=remote repo="))

    def test_text_same_head_unsigned_repeats_sign_gates(self):
        self.seed();Path(self.log).write_text("")
        r=self.text_pull("--sign","bin/ra=com.test.ra","--codesign",os.path.join(FIX,"fake-codesign"),"--security",os.path.join(FIX,"fake-security"))
        self.assertIn("/zip",Path(self.log).read_text(),"unsigned ordinary text repeats signing gates")
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(r.stdout.startswith("promoted app=remote repo="))

    def test_public_puller_text_default(self):
        env=dict(os.environ);env.update({"LAST_STACK_GH":os.path.join(FIX,"fake-gh"),"LAST_STACK_LASTGIT":os.path.join(FIX,"fake-lastgit"),"FAKE_GH_ROUTES":self.routes_path,"FAKE_GH_LOG":self.log,"LAST_STACK_SITUATIONS_BIN":"/usr/bin/true"})
        r=subprocess.run([sys.executable,PULL,"--app","remote","--repo",REPO,"--root",self.cas],env=env,capture_output=True,text=True,timeout=15)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertTrue(r.stdout.startswith("promoted app=remote repo="),"public text default stays text")
        with self.assertRaises(json.JSONDecodeError):json.loads(r.stdout)


    def pull_module(self):
        import importlib.machinery, importlib.util
        loader=importlib.machinery.SourceFileLoader("canonical_pull_fixture",PULL)
        spec=importlib.util.spec_from_loader(loader.name,loader)
        module=importlib.util.module_from_spec(spec);loader.exec_module(module)
        return module

    def direct_tuple_refusal(self, mutate, label):
        module=self.pull_module()
        man={"files":[{"path":"file","sha256":"a"*64,"size":1,"mode":493}]}
        mutate(man)
        caught=False
        try:module.canonical_file_tuples(man)
        except (module.Hold,module.Fail):caught=True
        except Exception as error:self.fail(label+" typed refusal: "+str(error))
        self.assertTrue(caught,label+" typed refusal")

    def test_tuple_guard_list(self):self.direct_tuple_refusal(lambda m:m.__setitem__("files",{}),"tuple-list")
    def test_tuple_guard_item(self):self.direct_tuple_refusal(lambda m:m["files"].__setitem__(0,"WRONG"),"tuple-item")
    def test_tuple_guard_field_set(self):self.direct_tuple_refusal(lambda m:m["files"][0].pop("mode"),"tuple-fields")
    def test_tuple_guard_path_type(self):self.direct_tuple_refusal(lambda m:m["files"][0].__setitem__("path",123),"tuple-path-type")
    def test_tuple_guard_digest_type(self):self.direct_tuple_refusal(lambda m:m["files"][0].__setitem__("sha256",123),"tuple-digest-type")
    def test_tuple_guard_digest_format(self):self.direct_tuple_refusal(lambda m:m["files"][0].__setitem__("sha256","z"*64),"tuple-digest-format")
    def test_tuple_guard_size_type(self):self.direct_tuple_refusal(lambda m:m["files"][0].__setitem__("size",True),"tuple-size-type")
    def test_tuple_guard_size_range(self):self.direct_tuple_refusal(lambda m:m["files"][0].__setitem__("size",-1),"tuple-size-range")
    def test_tuple_guard_mode_type(self):self.direct_tuple_refusal(lambda m:m["files"][0].__setitem__("mode",493.0),"tuple-mode-type")
    def test_tuple_guard_mode_range(self):self.direct_tuple_refusal(lambda m:m["files"][0].__setitem__("mode",0o1000),"tuple-mode-range")
    def test_tuple_guard_duplicate(self):self.direct_tuple_refusal(lambda m:m["files"].append(dict(m["files"][0])),"tuple-duplicate")
    def test_tuple_guard_safe_path(self):self.direct_tuple_refusal(lambda m:m["files"][0].__setitem__("path","../escape"),"tuple-safe-path")

    def test_direct_canonical_digest_guard(self):
        from unittest.mock import patch
        module=self.pull_module()
        man={"schema_version":1,"app":"remote","repo":"remote","source_oid":self.oid,"platform":"darwin-arm64","manifest_digest":"z"*64,"files":[{"path":"file","sha256":"a"*64,"size":1,"mode":493}]}
        with patch.object(module,"canonical_json_file",return_value=man),patch.object(module,"lastgit",return_value=""):
            with self.assertRaises(module.Hold,msg="canonical digest format refuses before a verified receipt"):
                module.reuse_canonical_manifest(self.cas,"remote","remote",self.oid,"darwin-arm64",man["files"],False,"unused")

    def test_direct_nonregular_stat_guard(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        module=self.pull_module();path=Path(self.d)/"stat-shape.json";path.write_text('{"x":1}')
        with patch.object(module.os,"fstat",return_value=SimpleNamespace(st_mode=stat.S_IFIFO|0o600,st_size=7)):
            with self.assertRaises(module.Hold,msg="nonregular stat refuses before JSON acceptance"):
                module.canonical_json_file(path)

    def test_direct_read_byte_cap_guard(self):
        from types import SimpleNamespace
        from unittest.mock import patch
        module=self.pull_module();path=Path(self.d)/"grow-shape.json"
        # The JSON prefix stays valid if the read cap clips trailing spaces.
        # A stale stat models a regular file that grows after fstat.
        path.write_bytes(b'{"x":1}'+b' '*(module.CANONICAL_MANIFEST_MAX_BYTES+1))
        with patch.object(module.os,"fstat",return_value=SimpleNamespace(st_mode=stat.S_IFREG|0o600,st_size=7)):
            with self.assertRaises(module.Hold,msg="grown canonical file refuses at the read byte cap"):
                module.canonical_json_file(path)

    def test_public_hosttrack_passes_real_json_argv(self):
        first=self.seed()
        bindir=os.path.join(self.d,"runtime-bin");os.makedirs(bindir)
        wrapper=os.path.join(bindir,"lastgit")
        with open(wrapper,"w") as fh:
            fh.write("#!/usr/bin/env python3\nimport json,os,subprocess,sys\na=sys.argv[1:]\n")
            fh.write("if a[:2]==['artifact','resolve']:\n print(open(os.path.join(%r,'channels',a[a.index('--app')+1],a[a.index('--channel')+1]+'.json')).read());sys.exit(0)\n"%self.cas)
            fh.write("sys.exit(subprocess.run([%r]+a).returncode)\n"%os.path.join(FIX,"fake-lastgit"))
        os.chmod(wrapper,0o755)
        lastdb=os.path.join(bindir,"lastdb")
        with open(lastdb,"w") as fh:
            fh.write("#!/usr/bin/env python3\nimport json,sys\nif '--help' in sys.argv:print('usage');sys.exit(0)\nprint(json.dumps({'sha':%r,'proved_at':'2026-10-09T00:00:00Z','proof_run':'fixture'}))\n"%self.oid)
        os.chmod(lastdb,0o755)
        registry=os.path.join(self.d,"registry.json")
        with open(registry,"w") as fh:
            json.dump({"defaults":{"artifact_channel":"stable"},"apps":[{"app":"remote","command":"ra","kind":"artifact-bundle","install_mode":"artifact","gate_main":"https://github.com/EdgeVector/remote.git#main","artifact_root":self.cas,"install_root":os.path.join(self.d,"installed"),"registry_channel":"next","registry_index":os.path.join(self.d,"index.json"),"links":[],"safe_upgrade":{"soak_hours":0,"probes":[{"argv":["bin/ra"],"output_matches":"ra"}]}}]},fh)
        env=dict(os.environ)
        env.update({"PATH":bindir+os.pathsep+env["PATH"],"HOST_TRACK_REGISTRY":registry,"HOST_TRACK_STAMP_DIR":os.path.join(self.d,"stamps"),"HOST_TRACK_LOCK_DIR":os.path.join(self.d,"locks"),"HOST_TRACK_FRONTIER_DIR":os.path.join(self.d,"frontier"),"HOST_TRACK_GITHUB_PULL":PULL,"HOST_TRACK_ARTIFACT_ROOT":self.cas,"HOST_TRACK_ROOT":ROOT,"LAST_STACK_GH":os.path.join(FIX,"fake-gh"),"LAST_STACK_LASTGIT":os.path.join(FIX,"fake-lastgit"),"FAKE_GH_ROUTES":self.routes_path,"FAKE_GH_LOG":self.log,"LAST_STACK_SITUATIONS_BIN":"/usr/bin/true","HOST_TRACK_SOAK_FILE_CARD":"0","HOST_TRACK_SOAK_HEAL":"0","HOST_TRACK_SHIP_SOAK_RESUME":"0","HOST_TRACK_REOPEN_DEFERRED":"0"})
        for key in ["HOST_TRACK_ACTIVATE","HOST_TRACK_PROBE_SKIP","HOST_TRACK_REEXECED","HOST_TRACK_REGISTRY_INDEX"]:env.pop(key,None)
        args=[os.path.join(ROOT,"bin","host-track"),"install","--channel","candidate","--expected-oid",self.oid,"--expected-manifest",first["manifest_digest"],"--json","remote"]
        r=subprocess.run(args,env=env,capture_output=True,text=True,timeout=45)
        result=json.loads(r.stdout)
        self.assertTrue(result.get("exact_match"),"actual public JSON argv produces exact receipt: "+r.stderr)
        self.assertEqual((r.returncode,result.get("result"),result["official"]["run_id"],result["official"]["artifact_id"]),(0,"installed",77,5))



if __name__ == "__main__":
    unittest.main(verbosity=1)
