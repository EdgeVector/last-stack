"""Bind a closed route to a fresh observation of the live primary ENB writer."""

from native_upgrade_common import require
from native_run_v2_auto_writer_policy import SCOPE, SETTINGS
from native_run_v2_inputs import digest, reference, uint
from native_run_v2_routes import route


def approved(original, source, programs, plist_path):
    value = reference(original, 65536)
    require(value.get("schema") == "lastdb.primary-writer-policy-observation.v1"
            and value.get("source") == source and value.get("programs") == programs
            and value.get("settings") == SETTINGS and value.get("effective_process_matches_plist") is True
            and type(value.get("primary_effects")) is int and value["primary_effects"] == 0,
            "The writer policy differs from an actual primary ENB observation of the exact pair")
    identity, plist = value.get("session"), value.get("launchd_plist")
    require(isinstance(identity, dict) and set(identity) == {"pid", "start_ts"}
            and uint(identity["pid"], True) and uint(identity["start_ts"], True)
            and isinstance(plist, dict) and set(plist) == {"path", "sha256"}
            and plist["path"] == plist_path and digest(plist["sha256"])
            and uint(value.get("observed_at"), True) >= identity["start_ts"],
            "The primary writer identity is incomplete")
    return {"result": original, "observation": value, "scope": SCOPE}


def baseline(approval):
    selected = route(approval)
    return approved(approval.get("baseline_writer_policy"), selected["baseline"],
                    approval["baseline_programs_sha256"], approval["launchd_plist"])


def development(approval, dev_route, dev_baseline_programs):
    """The writer policy that the main Mac DEV operation used."""
    if route(approval)["kind"] != "activation":
        require("development_writer_policy" not in approval,
                "Only an activation route names a separate DEV writer policy")
        return baseline(approval)
    return approved(approval.get("development_writer_policy"), dev_route["baseline"],
                    dev_baseline_programs, approval["launchd_plist"])


def initial(approval, live, plist):
    observed = baseline(approval)["observation"]
    require(live["session"] == observed["session"]
            and live["plist_sha256"] == observed["launchd_plist"]["sha256"]
            and {name: item["sha256"] for name, item in live["pair"].items()} == observed["programs"]
            and all(plist.get("EnvironmentVariables", {}).get(name) == value for name, value in SETTINGS.items()),
            "The live primary pair, session, or configuration differs from its ENB writer observation")
