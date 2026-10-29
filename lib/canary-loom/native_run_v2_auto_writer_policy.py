"""Bind format4 qualification to the actual primary ENB writer policy."""

from native_upgrade_common import require
from native_run_v2_auto_source import BASELINE, BASELINE_PROGRAMS
from native_run_v2_inputs import digest, reference, uint

RECEIPT = "af1f22e02e694e883d06d28e45a2ac244e267626b0865dfbb9514f808b6b9cce"
SETTINGS = {"LASTDB_AT_REST_RAW": "1", "LASTDB_KV_AT_REST_COMPRESS": "1", "LASTDB_KV_AT_REST_RAW": "1"}
SCOPE = "primary-observed ENB writer profile; default and legacy CAS formats are not qualified"


def approved(approval):
    original = approval.get("baseline_writer_policy")
    value = reference(original, 65536)
    require(original["sha256"] == RECEIPT
            and value.get("schema") == "lastdb.primary-writer-policy-observation.v1"
            and value.get("source") == BASELINE and value.get("programs") == BASELINE_PROGRAMS
            and value.get("settings") == SETTINGS and value.get("effective_process_matches_plist") is True
            and type(value.get("primary_effects")) is int and value["primary_effects"] == 0,
            "The baseline writer policy differs from the actual primary ENB observation")
    identity, plist = value.get("session"), value.get("launchd_plist")
    require(isinstance(identity, dict) and set(identity) == {"pid", "start_ts"}
            and uint(identity["pid"], True) and uint(identity["start_ts"], True)
            and isinstance(plist, dict) and set(plist) == {"path", "sha256"}
            and plist["path"] == approval["launchd_plist"] and digest(plist["sha256"])
            and uint(value.get("observed_at"), True), "The original primary writer identity is incomplete")
    return {"result": original, "observation": value, "scope": SCOPE}


def development(binding, intent, summary):
    require(intent.get("writer_policy") == summary.get("writer_policy") == binding
            and summary.get("default_cas_formats_qualified") is False,
            "The DEV operation does not use the exact observed primary ENB writer policy")


def initial(approval, baseline, plist):
    binding = approved(approval)
    observed = binding["observation"]
    require(baseline["session"] == observed["session"]
            and baseline["plist_sha256"] == observed["launchd_plist"]["sha256"]
            and {name: item["sha256"] for name, item in baseline["pair"].items()} == observed["programs"]
            and all(plist.get("EnvironmentVariables", {}).get(name) == value for name, value in SETTINGS.items()),
            "The initial primary pair, session, or configuration differs from the ENB writer observation")
