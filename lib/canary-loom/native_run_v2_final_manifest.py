"""Retain only the original final-source metadata, then hash the stopped files."""
import hashlib
import json
from pathlib import Path

from native_upgrade_common import require, save, sha
from native_run_v2_inputs import digest, reference, uint
from native_run_v2_recovery import FILE, local, native_hash, selectors
from native_run_v2_state import stable
from native_run_v2_routes import markers, stopped_marker


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def decimal(value):
    require(isinstance(value, str) and value.isascii() and value.isdecimal()
            and str(int(value)) == value and int(value) < 2**64,
            "A final backup decimal counter differs")
    return int(value)


def retain(job, directory):
    source = local(job / "stopped-source.json")
    require(source.get("version") == 1 and 0 < uint(source.get("objects"), True) <= 1000000,
            "The final source manifest is absent or exceeds its bound")
    chain = hashlib.sha256(b"lastdb:stopped-byte-source-manifest:v1\0")
    files, size = [], 0
    for index in range(source["objects"]):
        descriptor = local(job / f"stopped-object-{index:08}.json")
        encoded = canonical(descriptor)
        size += len(encoded)
        require(size <= 16 * 1024 * 1024 and descriptor.get("input", {}).get("job") == source["begin"]["job"]
                and isinstance(descriptor.get("native_files"), list),
                "The final source descriptor identity or metadata size differs")
        chain.update(index.to_bytes(8, "big"))
        chain.update(len(encoded).to_bytes(8, "big"))
        chain.update(encoded)
        files.extend(descriptor["native_files"])
    require(chain.hexdigest() == digest(source.get("descriptors_sha256"))
            and 0 < len(files) <= 1000000 and len(files) == source.get("native_files")
            and sum(decimal(f["native_bytes"]) for f in files) == source.get("native_bytes"),
            "The complete original final-source metadata differs")
    retained = {**source, "native_file_manifest": files}
    target = directory / "final-stopped-source.json"
    if target.exists():
        require(reference({"path": str(target), "sha256": sha(target)}) == retained,
                "A retained final source differs from the original")
    else:
        save(target, retained)
    return {"path": str(target), "sha256": sha(target)}


def verify(approval, state, report, manifest):
    home = Path(approval["primary_home"])
    profile = report["run_profile"]
    require(manifest.get("begin") == report["accepted_backup"]["begin"]
            and manifest.get("run_profile") == profile
            and manifest.get("native_files") == report.get("native_files")
            and manifest.get("native_bytes") == report.get("native_bytes"),
            "The accepted final source metadata differs")
    metadata, roots = selectors(home, profile, stopped=True, marker=stopped_marker(approval))
    try:
        require(roots == state["stopped_native_roots"]
                and stable(home, markers(approval)) == state["baseline"]["stable"],
                "The final stopped native roots or stable home changed")
        found = {}
        for item in manifest["native_file_manifest"]:
            path = item["path"]
            require(path not in found and (path == "laststore-pack-node-v1" or FILE.fullmatch(path)),
                    "A final native path is duplicated or invalid")
            count = decimal(item["native_bytes"])
            require(0 < count <= 2**40 and native_hash(home / "data" / path, count)
                    == digest(item["native_sha256"]), "The complete stopped native file hash differs")
            found[path] = count
        required = {"laststore-pack-node-v1", "disk-run/CURRENT", "disk-cas/CURRENT",
                    "disk-run/laststore-run-home-v2", "disk-cas/laststore-run-home-v2"}
        require(required <= found.keys() and len(found) == report["native_files"]
                and sum(found.values()) == report["native_bytes"],
                "The final stopped native file set is incomplete")
        return {"native_files": len(found), "native_bytes": sum(found.values()), "selectors": roots}
    finally:
        metadata.close()
