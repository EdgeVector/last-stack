"""Recognize only the exact final capture's temporary native metadata links."""
from pathlib import Path
import uuid

from native_upgrade_common import require
from native_run_v2_recovery import wrapped
from native_run_v2_state import Metadata


def normalize(approval, state, observed):
    expected = state["baseline"]["stable"]
    pairs = [(observed["node_marker"], expected["node_marker"], "node")]
    for name, label in (("disk-run", "main"), ("disk-cas", "cas")):
        pairs.append((observed["run_homes"][name]["descriptor"],
                      expected["run_homes"][name]["descriptor"], label + "/descriptor"))
    changed = [(actual, before, held) for actual, before, held in pairs
               if actual.get("nlink") != before.get("nlink")]
    if not changed:
        return observed
    request = approval["final_backup"]["request_id"]
    require(approval.get("schema") == "lastdb.run-v2-maintenance-approval.v2"
            and state.get("final_backup_requested") == request,
            "The primary has an unowned native metadata link")
    home = Path(approval["primary_home"])
    source = home / "data/disk-run/cloud-byte-source-v2"
    metadata = Metadata()
    try:
        metadata.directory(source)
        intent = wrapped(source / "run-intent.json")
        require(intent["begin"]["job"]["commit_id"] == request
                and intent["begin"]["job"]["stream"] == approval["recovery"]["accepted_backup"]["begin"]["job"]["stream"],
                "The retained capture belongs to another final request or stream")
        identity = intent["reference_id"]
        require(str(uuid.UUID(identity)) == identity and uuid.UUID(identity).int != 0,
                "The retained final capture identity differs")
        parent = home / "data/disk-run/cloud-byte-holds-v2"
        metadata.directory(parent)
        root = parent / identity
        metadata.directory(root)
        for actual, before, held in changed:
            require(before.get("nlink") == 1 and actual.get("nlink") == 2
                    and {**actual, "nlink": 1} == before,
                    "The final capture changed native metadata beyond its one retained link")
            path = root / held
            directory = metadata.directory(path.parent)
            link, unused = metadata.file(directory, path.name, 128, exact=before["size"])
            require(all(link.get(key) == actual[key] for key in link),
                    "The extra native link is not the exact final held inode")
            actual["nlink"] = 1
        return observed
    finally:
        metadata.close()
