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
        # Second run: channel already at the tip, no artifact download.
        open(self.log, "w").close()
        rc, res, _ = self.pull()
        self.assertEqual((rc, res["status"]), (0, "current"))
        self.assertNotIn("/zip", open(self.log).read())

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
    def sign_pull(self, *extra, env=None):
        for k in ("FAKE_CODESIGN_FAIL", "FAKE_SECURITY_NONE", "FAKE_SECURITY_TWO"):
            os.environ.pop(k, None)
        os.environ.update(env or {})
        self.addCleanup(lambda: [os.environ.pop(k, None) for k in (env or {})])
        return self.pull("--sign", "bin/ra=com.test.ra", "--codesign", os.path.join(FIX, "fake-codesign"),
                         "--security", os.path.join(FIX, "fake-security"), *extra)

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

    def unsigned_promote(self):
        rc, res, err = self.pull()
        self.assertEqual((rc, res.get("status")), (0, "promoted"), err)
        return res

    def chan(self):
        return json.load(open(os.path.join(self.cas, "channels", "remote", "stable.json")))

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
        self.assertEqual((rc, res.get("status")), (0, "current"), err)
        self.assertNotIn("/zip", open(self.log).read())

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
        self.assertEqual((rc, res["status"]), (0, "current"))

    def test_routines_default_sign_table(self):
        sys.path.insert(0, os.path.join(ROOT, "bin"))
        import importlib.machinery, importlib.util
        loader = importlib.machinery.SourceFileLoader("pull_mod", PULL)
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("pull_mod", loader))
        loader.exec_module(mod)
        self.assertEqual(mod.SIGN_DEFAULTS["routines"], [("dist/routines", "com.edgevector.routines")])


if __name__ == "__main__":
    unittest.main(verbosity=1)
