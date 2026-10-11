"""Recheck the actual hosted install/startup proof before stable promotion."""
from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import re
from concurrent.futures import ThreadPoolExecutor

from release_registry import Refused


def selected_rows(index, build):
    rows = []
    for app in index["apps"]:
        candidates = [row for row in app.get("compat", []) if row.get("lastdb_version") == build]
        if not candidates:
            continue
        # Match registry-index promote's exact latest-row selection.
        row = max(candidates, key=lambda item: (item.get("proved_at", ""), item.get("app_version", "")))
        identity = (app.get("app_id"), row.get("sha"), row.get("proof_run"))
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", identity[0] or ""):
            raise Refused("promoted app identity is invalid")
        if not re.fullmatch(r"[0-9a-f]{40}", identity[1] or ""):
            raise Refused("promoted app source is not an exact OID")
        if not isinstance(identity[2], str):
            raise Refused("promoted proof identity is invalid")
        rows.append(identity)
    if not rows or len({row[0] for row in rows}) != len(rows):
        raise Refused("no exact unique proved rows exist for this Mini build")
    return sorted(rows)


def verifier(root):
    loader = importlib.machinery.SourceFileLoader("stable_hosted_verifier", str(root / "bin/last-stack-registry-apply-proof"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def verify_one(module, tap, proof_run, apps, build, oid, scratch):
    match = re.fullmatch(r"ci-smoke-([0-9]+)-" + re.escape(module.safe_build(build)), proof_run or "")
    if not match:
        raise Refused("stable requires the current hosted install/startup proof identity")
    record = tap / "registry/proofs" / f"{proof_run}.json"
    if not record.is_file() or record.stat().st_size > 1024 * 1024:
        raise Refused("hosted proof record missing or exceeds 1 MiB")
    try:
        saved = json.loads(record.read_text(encoding="utf-8"))
        if saved.get("proof_kind") != "app_install_startup" or saved.get("lastdb_build") != build:
            raise Refused("saved proof does not match the real install/startup producer")
        candidate = saved.get("candidate_set") or {}
        if (candidate.get("lastdb") or {}).get("oid") != oid:
            raise Refused("saved proof Mini source differs from the selected artifact")
        if any((candidate.get("apps", {}).get(app) or {}).get("sha") != sha for app, sha in apps.items()):
            raise Refused("saved proof app source differs from the signed rows")
        run_id = match.group(1)
        repo = "EdgeVector/last-stack"
        run = module.gh_json("api", f"repos/{repo}/actions/runs/{run_id}")
        conclusion = module.verify_run(run or {}, repo, run_id)
        bundle = module.download_bundle(repo, run_id, scratch / run_id)
        manifest = module.verify_bundle(bundle, run or {}, repo, run_id, conclusion, build, oid, apps)
        if manifest["proof_run"] != proof_run:
            raise Refused("hosted proof record differs from the signed row")
    except Refused:
        raise
    except (Exception, SystemExit) as exc:
        raise Refused("the actual hosted install/startup proof refused") from exc


def verify_hosted(root, tap, rows, build, oid, scratch):
    grouped = {}
    for app, sha, proof_run in rows:
        apps = grouped.setdefault(proof_run, {})
        if app in apps and apps[app] != sha:
            raise Refused("one proof names conflicting app sources")
        apps[app] = sha
    if len(grouped) > 16:
        raise Refused("stable proof set exceeds the declared sixteen-run bound")
    module = verifier(root)
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(verify_one, module, tap, proof_run, apps, build, oid, scratch)
                   for proof_run, apps in grouped.items()]
        for future in futures:
            future.result()
