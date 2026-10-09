#!/usr/bin/env python3
"""Public HostTrack fixture. All state and command doubles use one private root."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CASE = sys.argv[1] if len(sys.argv) > 1 else None
OID = "2" * 40
TREE = "3" * 40
DIGEST = "b" * 64
OLD_OID = "1" * 40
OLD_DIGEST = "a" * 64

STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
r = pathlib.Path(os.environ["HT_FIXTURE_ROOT"])
c = json.loads((r / "control.json").read_text())
a = sys.argv[1:]
name = pathlib.Path(sys.argv[0]).name
with (r / "events.jsonl").open("a") as f: f.write(json.dumps({"command": name, "argv": a}) + "\n")
def value(flag):
    assert a.count(flag) == 1, (flag, a)
    return a[a.index(flag)+1]
if name == "lastdb":
    assert a[:2] == ["app", "resolve"], a
    if a[2:] == ["--help"]:
        if c.get("registry_unsupported"): sys.exit(2)
        print("usage"); sys.exit(0)
    assert a[2] == "demo" and value("--channel") == "next" and value("--index") == str(r / "index.json"), a
    if c.get("registry_hold"):
        print("error: no next row was proved with lastdb fixture", file=sys.stderr); sys.exit(1)
    if c.get("registry_unreadable"):
        print("error: failed to read registry", file=sys.stderr); sys.exit(1)
    print(json.dumps({"sha": c["registry_oid"], "proved_at": "2026-10-09T00:00:00Z", "proof_run": "fixture-proof"})); sys.exit(0)
if name == "lastgit":
    assert a[:2] == ["artifact", "resolve"], a
    assert value("--app") in ("demo", "dep", "plain") and value("--root") == str(r / "cas"), a
    app = value("--app")
    channel = value("--channel")
    assert channel in ("stable", "candidate"), a
    print((r / "cas/channels" / app / (channel + ".json")).read_text()); sys.exit(0)
if name == "official-pull":
    assert value("--app") == "demo" and value("--repo") == "EdgeVector/demo" and value("--branch") == "main", a
    assert value("--root") == str(r / "cas"), a
    channel = value("--channel")
    rc = c.get("pull_rc", 0)
    if rc: print("official pull refused", file=sys.stderr); sys.exit(rc)
    if "--oid" in a: assert value("--oid") == c["expected_oid"], a
    manifest = json.loads((r / "cas/manifests" / (c["pull_digest"] + ".json")).read_text())
    (r / "cas/channels/demo" / (channel + ".json")).write_text(json.dumps(manifest))
    result = {"status": "promoted", "oid": c["pull_oid"], "tree_oid": c["tree_oid"], "manifest_digest": c["pull_digest"], "platform": value("--platform"), "channel": channel, "artifact_id": 23, "run_id": 17}
    if c.get("bad_provenance"): del result["tree_oid"]
    if c.get("provenance_field"): result[c["provenance_field"]] = c["provenance_value"]
    if c.get("provenance_multiple"): print(json.dumps({"status":"WRONG"}))
    print(json.dumps(result)); sys.exit(0)
raise AssertionError(name)
'''

PAYLOAD = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
r = pathlib.Path(os.environ["HT_FIXTURE_ROOT"])
c = json.loads((r / "control.json").read_text())
with (r / "events.jsonl").open("a") as f: f.write(json.dumps({"command": "probe", "argv": sys.argv[1:]}) + "\n")
if c.get("drift"):
    manifest = json.loads((r / "cas/channels/demo/candidate.json").read_text())
    manifest[c["drift"]] = c["drift_value"]
    (r / "cas/channels/demo/candidate.json").write_text(json.dumps(manifest))
    c["registry_oid"] = manifest["source_oid"]
    # The registry resolve selects the published manifest for its source.
    (r / "cas/manifests" / (manifest["manifest_digest"] + ".json")).write_text(json.dumps(manifest))
    c.pop("drift")
    (r / "control.json").write_text(json.dumps(c))
if c.get("probe_fail"): sys.exit(1)
print("exact-probe-ok")
'''

def require(condition, message):
    if not condition:
        raise AssertionError(message)

class Fixture:
    def __init__(self, root):
        self.r = root
        self.control = {"registry_oid": OID, "expected_oid": OID, "pull_oid": OID,
                        "pull_digest": DIGEST, "tree_oid": TREE}
        for p in ["bin", "cas/manifests", "cas/channels/demo", "stamps", "locks", "links"]:
            (root / p).mkdir(parents=True, exist_ok=True)
        for name in ["lastgit", "lastdb", "official-pull"]:
            path = root / "bin" / name
            path.write_text(STUB)
            path.chmod(0o755)
        (root / "index.json").write_text("{}\n")
        app = {"app": "demo", "install_mode": "artifact", "kind": "artifact-bundle", "command": "demo",
               "gate_main": "https://github.com/EdgeVector/demo.git#main", "artifact_root": str(root / "cas"),
               "install_root": str(root / "installed"), "registry_channel": "next", "registry_index": str(root / "index.json"),
               "links": [{"source": "bin/demo", "target": str(root / "links/demo")}],
               "safe_upgrade": {"soak_hours": 0.001, "min_checks": 2,
                                "probes": [{"argv": ["bin/demo"], "timeout_s": 5, "output_matches": "exact-probe-ok"}]}}
        self.registry = {"defaults": {"install_mode": "artifact", "artifact_channel": "stable"}, "apps": [app]}
        self.publish(OLD_DIGEST, OLD_OID)
        self.publish(DIGEST, OID)
        (root / "cas/channels/demo/stable.json").write_text((root / "cas/manifests" / (OLD_DIGEST + ".json")).read_text())
        (root / "cas/channels/demo/candidate.json").write_text((root / "cas/manifests" / (DIGEST + ".json")).read_text())
        self.env = os.environ.copy()
        self.env.update({"HT_FIXTURE_ROOT": str(root), "HOST_TRACK_REGISTRY": str(root / "registry.json"),
                         "HOST_TRACK_STAMP_DIR": str(root / "stamps"), "HOST_TRACK_FRONTIER_DIR": str(root / "frontier"),
                         "HOST_TRACK_LOCK_DIR": str(root / "locks"), "HOST_TRACK_INSTALL_ROOT": str(root / "apps"),
                         "HOST_TRACK_ARTIFACT_ROOT": str(root / "cas"), "HOST_TRACK_GITHUB_PULL": str(root / "bin/official-pull"),
                         "HOST_TRACK_SOAK_FILE_CARD": "0", "HOST_TRACK_SOAK_HEAL": "0",
                         "HOST_TRACK_SHIP_SOAK_RESUME": "0", "HOST_TRACK_REOPEN_DEFERRED": "0",
                         "PATH": str(root / "links") + os.pathsep + str(root / "bin") + os.pathsep + os.environ["PATH"]})
        for name in ["HOST_TRACK_ACTIVATE", "HOST_TRACK_PROBE_SKIP", "HOST_TRACK_ROOT", "HOST_TRACK_REEXECED", "HOST_TRACK_REGISTRY_INDEX"]:
            self.env.pop(name, None)
        self.save()

    def publish(self, digest, oid):
        data = PAYLOAD.encode()
        sha = hashlib.sha256(data).hexdigest()
        blob = self.r / "cas/blobs/sha256" / sha[:2] / sha
        blob.parent.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(data)
        manifest = {"schema_version": 1, "app": "demo", "repo": "demo", "source_oid": oid,
                    "platform": "fixture", "created_at": "2026-10-09T00:00:00Z",
                    "files": [{"path": "bin/demo", "sha256": sha, "size": len(data), "mode": 493}],
                    "manifest_digest": digest}
        (self.r / "cas/manifests" / (digest + ".json")).write_text(json.dumps(manifest))

    def save(self):
        (self.r / "control.json").write_text(json.dumps(self.control))
        (self.r / "registry.json").write_text(json.dumps(self.registry))

    def events(self):
        p = self.r / "events.jsonl"
        return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []

    def current(self):
        p = self.r / "installed/current"
        return os.readlink(p) if p.is_symlink() else None

    def run(self, *args, exact=True):
        self.save()
        command = [str(ROOT / "bin/host-track"), "install"]
        if exact:
            command += ["--channel", "candidate", "--expected-oid", OID, "--expected-manifest", DIGEST, "--json"]
        command += list(args) if args else ["demo"]
        result = subprocess.run(command, env=self.env, text=True, capture_output=True, timeout=45)
        (self.r / "stdout").write_text(result.stdout)
        (self.r / "stderr").write_text(result.stderr)
        if exact:
            if self.control.get("require_no_registry_fallback"):
                require(not any(e["command"] in ["lastgit","probe"] for e in self.events()), "registry unavailable no fallback")
            if self.control.get("require_no_downstream"):
                require(not any(e["command"] in ["lastdb","lastgit","probe"] for e in self.events()), "strict pull no old-channel fallback")
            try: receipt = json.loads(result.stdout)
            except Exception as error: raise AssertionError("one JSON receipt: " + result.stdout + " stderr=" + result.stderr) from error
            require(isinstance(receipt, dict) and receipt.get("version") == 1, "typed v1 receipt")
            return result, receipt
        return result, None

    def bootstrap(self):
        saved = dict(self.control)
        self.control.update(registry_oid=OLD_OID, pull_oid=OLD_OID, pull_digest=OLD_DIGEST)
        result, _ = self.run(exact=False)
        require(result.returncode == 0 and self.current() == "versions/" + OLD_DIGEST, "baseline bootstrap")
        self.control = saved
        (self.r / "events.jsonl").write_text("")

def check_refusal(f, receipt, result, before, before_stamp):
    require(f.current() == before, "no target activation")
    require((f.r/"stamps/demo.json").read_text()==before_stamp, "no install stamp publication")
    require(not (f.r/"installed/canary").is_symlink(), "no accepted canary publication")
    require(receipt.get("exact_match") is False and receipt.get("result") != "installed", "no false installed receipt")
    require(result.returncode != 0, "refusal exit")

def execute(name, f):
    if name in ["success", "dependency-positive"]:
        if name == "dependency-positive":
            f.registry["apps"][0]["requires"] = ["dep"]
            dep = dict(f.registry["apps"][0])
            dep.update(app="dep",command="dep",requires=[],registry_channel="",gate_main="",track_gate_main=False,
                       install_root=str(f.r/"installed-dep"),links=[{"source":"bin/demo","target":str(f.r/"links/dep")}])
            f.registry["apps"].append(dep)
            manifest=json.loads((f.r/"cas/manifests"/(OLD_DIGEST+".json")).read_text())
            manifest.update(app="dep",repo="dep",manifest_digest="d"*64)
            (f.r/"cas/manifests"/("d"*64+".json")).write_text(json.dumps(manifest))
            (f.r/"cas/channels/dep").mkdir()
            (f.r/"cas/channels/dep/stable.json").write_text(json.dumps(manifest))
        result, receipt = f.run()
        if name == "dependency-positive":
            dependency_stamp = json.loads((f.r/"stamps/dep.json").read_text())
            require("exact_request" not in dependency_stamp and "exact_official" not in dependency_stamp, "dependency retains its own authority")
        require(f.current() == "versions/" + DIGEST, "exact target active")
        require(result.returncode == 0 and receipt["result"] == "installed" and receipt["exact_match"] is True, "exact success")
        require(receipt["requested"] == {"app": "demo", "channel": "candidate", "source_oid": OID, "manifest_sha256": DIGEST}, "immutable request")
        require(receipt["official"]["tree_oid"] == TREE and receipt["official"]["run_id"] == 17 and receipt["official"]["artifact_id"] == 23, "official provenance")
        require(receipt["installed"]["tree_oid"] == TREE and receipt["installed"]["source_oid"] == OID, "installed source and tree")
        require(receipt["installed"]["files"][0]["sha256"] == hashlib.sha256(PAYLOAD.encode()).hexdigest(), "actual installed SHA")
        require(any(e["command"] == "lastdb" for e in f.events()), "registry gate used")
        require(any(e["command"] == "probe" for e in f.events()), "probe gate used")
        pull = [e for e in f.events() if e["command"] == "official-pull"][-1]["argv"]
        require(pull[pull.index("--oid")+1] == OID and pull[pull.index("--channel")+1] == "candidate", "exact public pull argv")
    elif name == "matching-existing-soak":
        f.bootstrap()
        result, receipt = f.run()
        require(result.returncode == 75 and receipt["result"] == "pending", "matching exact request pending")
        ordinary, _ = f.run("demo", exact=False)
        stamp = json.loads((f.r/"stamps/demo.soak.json").read_text())
        require(ordinary.returncode == 0, "ordinary same-app park succeeds")
        require(stamp.get("exact_request") == receipt["requested"] and stamp.get("exact_official") == receipt["official"], "matching existing exact authority retained")
    elif name in ["cross-app-soak-complete", "cross-app-soak-pending", "foreign-existing-soak"]:
        f.bootstrap()
        plain = dict(f.registry["apps"][0])
        plain.update(app="plain",command="plain",requires=[],registry_channel="",gate_main="",track_gate_main=False,
                     install_root=str(f.r/"installed-plain"),links=[{"source":"bin/demo","target":str(f.r/"links/plain")}])
        plain["safe_upgrade"] = dict(plain["safe_upgrade"])
        f.registry["apps"].append(plain)
        (f.r/"cas/channels/plain").mkdir()
        for digest, oid in [("c"*64,"4"*40),("d"*64,"5"*40)]:
            manifest = json.loads((f.r/"cas/manifests"/(DIGEST+".json")).read_text())
            manifest.update(app="plain",repo="plain",source_oid=oid,manifest_digest=digest)
            (f.r/"cas/manifests"/(digest+".json")).write_text(json.dumps(manifest))
        channel = f.r/"cas/channels/plain/stable.json"
        channel.write_text((f.r/"cas/manifests"/("c"*64+".json")).read_text())
        plain_install, _ = f.run("plain", exact=False)
        require(plain_install.returncode == 0, "plain incumbent installed")
        channel.write_text((f.r/"cas/manifests"/("d"*64+".json")).read_text())
        result, receipt = f.run()
        require(result.returncode == 75 and receipt["result"] == "pending", "main exact request pending")
        plain_install, _ = f.run("plain", exact=False)
        require(plain_install.returncode == 0, "ordinary plain canary accepted")
        if name == "foreign-existing-soak":
            path = f.r/"stamps/plain.soak.json"
            stamp = json.loads(path.read_text())
            stamp.update(exact_request=receipt["requested"],exact_official=receipt["official"])
            path.write_text(json.dumps(stamp))
            ordinary, _ = f.run("plain", exact=False)
            stamp = json.loads(path.read_text())
            require(ordinary.returncode == 0 and "exact_request" not in stamp and "exact_official" not in stamp, "foreign existing exact authority not retained")
            return
        for app in ["demo","plain"]:
            path = f.r/"stamps"/(app+".soak.json")
            stamp = json.loads(path.read_text())
            if app == "demo" or name == "cross-app-soak-complete":
                stamp.update(started_epoch=0,checks=3)
            path.write_text(json.dumps(stamp))
        if name == "cross-app-soak-pending": plain["safe_upgrade"]["min_checks"]=100
        f.save()
        tick = subprocess.run([str(ROOT/"bin/host-track"),"soak-watch","--all"], env=f.env,text=True,capture_output=True,timeout=90)
        require(tick.returncode == 0 and f.current() == "versions/"+DIGEST, "first exact app completes in shared process")
        path = f.r/"stamps"/("plain.json" if name == "cross-app-soak-complete" else "plain.soak.json")
        stamp = json.loads(path.read_text())
        require("exact_request" not in stamp and "exact_official" not in stamp, "ordinary app has no foreign exact authority")
        target = os.readlink(f.r/"installed-plain/current")
        require(target == "versions/"+("d"*64 if name == "cross-app-soak-complete" else "c"*64), "ordinary app retains its own soak")
    elif name.startswith("parser-"):
        args = {"parser-pair": ["--expected-oid", OID, "--json", "demo"],
                "parser-hash": ["--expected-oid", "WRONG", "--expected-manifest", DIGEST, "--json", "demo"],
                "parser-manifest": ["--expected-oid", OID, "--expected-manifest", "WRONG", "--json", "demo"],
                "parser-activate": ["--channel","candidate","--expected-oid",OID,"--expected-manifest",DIGEST,"--json","demo"],
                "parser-probe": ["--channel","candidate","--expected-oid",OID,"--expected-manifest",DIGEST,"--json","demo"],
                "parser-channel": ["--channel", "WRONG", "--expected-oid", OID, "--expected-manifest", DIGEST, "--json", "demo"],
                "parser-multi": ["--expected-oid", OID, "--expected-manifest", DIGEST, "--json", "demo", "demo"],
                "parser-unknown": ["--unknown", "--expected-oid", OID, "--expected-manifest", DIGEST, "--json", "demo"]}[name]
        if name == "parser-activate": f.env["HOST_TRACK_ACTIVATE"]="1"
        if name == "parser-probe": f.env["HOST_TRACK_PROBE_SKIP"]="1"
        f.save()
        result = subprocess.run([str(ROOT / "bin/host-track"), "install"] + args, env=f.env, text=True, capture_output=True, timeout=10)
        require(not f.events() and f.current() is None, "no effect before parser refusal")
        receipt = json.loads(result.stdout)
        require(result.returncode != 0 and receipt["exact_match"] is False and receipt["result"] in ["failed", "refused"], "structured parser refusal")
    else:
        f.bootstrap()
        before = f.current()
        before_stamp=(f.r/"stamps/demo.json").read_text()
        if name in ["pull-held", "pull-failed"]: f.control["pull_rc"] = 3 if name == "pull-held" else 1
        elif name == "pull-tool-missing": f.env["HOST_TRACK_GITHUB_PULL"]=str(f.r/"absent-official-pull")
        elif name == "bad-provenance": f.control["bad_provenance"] = True
        elif name == "registry-mismatch": f.control["registry_oid"] = OLD_OID
        elif name == "registry-unavailable": f.control.update(registry_unsupported=True,require_no_registry_fallback=True)
        elif name == "provenance-multiple": f.control.update(provenance_multiple=True,require_no_downstream=True)
        elif name == "main-error": f.registry["apps"][0]["links"][0]["source"]="bin/absent"
        elif name == "registry-unreadable": f.control["registry_unreadable"] = True
        elif name == "pull-source-mismatch": f.control["pull_oid"] = OLD_OID
        elif name == "pull-manifest-mismatch": f.control["pull_digest"] = OLD_DIGEST
        elif name.startswith("provenance-"):
            field = name[len("provenance-"):]
            f.control["provenance_field"] = field
            f.control["provenance_value"] = {"status":"verified","channel":"stable","platform":"","run_id":True,"artifact_id":False}[field]
        elif name == "source-mismatch":
            f.control["registry_oid"] = OLD_OID
            old=json.loads((f.r/"cas/manifests"/(OLD_DIGEST+".json")).read_text());old["source_oid"]="9"*40
            (f.r/"cas/manifests"/(OLD_DIGEST+".json")).write_text(json.dumps(old))
            current=json.loads((f.r/"cas/manifests"/(DIGEST+".json")).read_text());current["source_oid"]=OLD_OID
            (f.r/"cas/manifests"/(DIGEST+".json")).write_text(json.dumps(current))
            f.registry["apps"][0]["safe_upgrade"]["soak_hours"]=0
        elif name == "manifest-mismatch":
            current=json.loads((f.r/"cas/manifests"/(DIGEST+".json")).read_text());current["manifest_digest"]=OLD_DIGEST
            (f.r/"cas/manifests"/(DIGEST+".json")).write_text(json.dumps(current))
            (f.r/"cas/manifests"/(OLD_DIGEST+".json")).write_text(json.dumps(current))
            f.registry["apps"][0]["safe_upgrade"]["soak_hours"]=0
        elif name == "stage-failed":
            current=json.loads((f.r/"cas/manifests"/(DIGEST+".json")).read_text())
            sha=current["files"][0]["sha256"]
            (f.r/"cas/blobs/sha256"/sha[:2]/sha).write_text("wrong bytes")
        elif name == "stamp-uncertain":
            # Reach final stamp publication rather than the earlier soak branch.
            f.registry["apps"][0]["safe_upgrade"]["soak_hours"]=0
            stamp=f.r/"stamps/demo.json"
            stamp.rename(f.r/"stamps/demo.baseline.json")
            stamp.mkdir()
        elif name == "dependency-refused":
            f.registry["apps"][0]["requires"]=["dep"]
            f.registry["apps"].append({"app":"dep","command":"private-missing-dependency-fixture","install_mode":"checkout"})
        elif name in ["source-drift", "manifest-drift"]:
            f.control["drift"] = "source_oid" if name == "source-drift" else "manifest_digest"
            f.control["drift_value"] = "9"*40 if name == "source-drift" else OLD_DIGEST
            f.registry["apps"][0]["safe_upgrade"]["soak_hours"] = 0
        elif name == "probe-failed": f.control["probe_fail"] = True
        if name.startswith("pull-") or name == "bad-provenance" or name.startswith("provenance-") or name == "dependency-refused":
            f.control["require_no_downstream"] = True
        result, receipt = f.run()
        if name.startswith("soak-"):
            require(f.current() == before and receipt["result"] == "pending" and receipt["exact_match"] is False, "soak no false activation")
            stamp_path = f.r / "stamps/demo.soak.json"
            stamp = json.loads(stamp_path.read_text())
            require(stamp.get("exact_request") == receipt["requested"], "soak retains exact request")
            stamp["started_epoch"] = 0
            stamp["checks"] = 3
            if name == "soak-request-drift": stamp["exact_request"]["source_oid"] = OLD_OID
            if name == "soak-request-app": stamp["exact_request"]["app"]="other"
            if name == "soak-request-manifest": stamp["exact_request"]["manifest_sha256"]=OLD_DIGEST
            if name == "soak-request-channel": stamp["exact_request"]["channel"] = "stable"
            stamp_path.write_text(json.dumps(stamp))
            if name == "soak-channel-drift":
                f.control["pull_oid"] = OLD_OID
                f.control["pull_digest"] = OLD_DIGEST
            f.save()
            old_events = len(f.events())
            tick = subprocess.run([str(ROOT / "bin/host-track"), "soak-watch", "demo"], env=f.env, text=True, capture_output=True, timeout=45)
            new_events = f.events()[old_events:]
            if name == "soak-success":
                require(tick.returncode == 0 and f.current() == "versions/" + DIGEST, "soak exact activation")
                result, receipt = f.run()
                require(receipt["exact_match"] is True and receipt["installed"]["tree_oid"] == TREE, "soak typed final receipt")
            else:
                pulls = [e for e in new_events if e["command"] == "official-pull"]
                if name in ["soak-request-drift","soak-request-channel","soak-request-app","soak-request-manifest"]: require(not pulls, "soak changed request no pull")
                require(f.current() == before, "soak drift no activation")
                require(len(pulls) <= 1, "soak drift no successor pull")
                require(not (f.r / "stamps/demo.soak.json").exists() or json.loads(stamp_path.read_text())["digest"] == DIGEST, "soak drift no successor stamp")
        elif name == "stamp-uncertain":
            require(receipt.get("exact_match") is False and receipt.get("result") != "installed", "uncertain stamp no success receipt")
            require(result.returncode != 0, "uncertain stamp refusal exit")
        else:
            check_refusal(f, receipt, result, before, before_stamp)
            if name == "dependency-refused":
                require(receipt["requested"]["app"] == "demo" and receipt["requested"]["source_oid"] == OID, "dependency refusal retains outer request")
            if name=="registry-unavailable": require(not any(e["command"] in ["lastgit","probe"] for e in f.events()), "registry unavailable no fallback")
            if name.startswith("pull-") or name == "bad-provenance" or name.startswith("provenance-") or name == "dependency-refused":
                require(not any(e["command"] in ["lastdb", "lastgit", "probe"] for e in f.events()), "strict pull no old-channel fallback")

CASES = ["success", "dependency-positive", "parser-pair", "parser-hash", "parser-channel", "parser-multi", "parser-unknown",
         "pull-held", "pull-failed", "bad-provenance", "registry-mismatch", "registry-unreadable",
         "source-mismatch", "manifest-mismatch", "source-drift", "manifest-drift", "probe-failed",
         "soak-success", "soak-channel-drift", "soak-request-drift", "pull-source-mismatch", "pull-manifest-mismatch",
         "provenance-status", "provenance-channel", "provenance-platform", "provenance-run_id", "provenance-artifact_id",
         "stage-failed", "dependency-refused", "stamp-uncertain", "soak-request-channel",
         "parser-manifest", "parser-activate", "parser-probe", "pull-tool-missing",
         "provenance-multiple", "registry-unavailable", "main-error", "soak-request-app", "soak-request-manifest",
         "cross-app-soak-complete", "cross-app-soak-pending", "foreign-existing-soak", "matching-existing-soak"]
if CASE is not None and CASE not in CASES: raise SystemExit("unknown case: " + CASE)
for name in [CASE] if CASE else CASES:
    with tempfile.TemporaryDirectory(prefix="host-track-exact-fixture-") as scratch:
        try:
            execute(name, Fixture(Path(scratch)))
        except Exception as error:
            print("FAIL: " + name + ": " + str(error), file=sys.stderr)
            raise
        print("ok " + name)
