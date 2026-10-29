"""Bind the current ENB writer to the original policy and actual program recovery."""

from pathlib import Path

from native_upgrade_common import require
from native_run_v2_auto_source import BASELINE, BASELINE_PROGRAMS, SOURCE
from native_run_v2_auto_writer_policy import SETTINGS, approved
from native_run_v2_inputs import digest, reference, uint


def identity(value):
    require(isinstance(value, dict) and set(value) == {"pid", "start_ts"}
            and all(uint(value[name], True) for name in ("pid", "start_ts")),
            "The recovered writer session is incomplete")
    return value


def original_approval(state, original):
    binding = state.get("binding", {})
    require(binding.get("safe_upgrade_protocol_version") == "14"
            and binding.get("upgrade_mode") == "native-run-v2-ci"
            and binding.get("source_git_oid") == SOURCE
            and binding.get("native_reopen") is False and binding.get("native_probe_only") is False,
            "The original writer recovery belongs to another upgrade policy")
    recorded = reference({"path": binding["native_approval"],
                          "sha256": digest(binding["native_approval_sha256"])}, 65536)
    require(recorded.get("schema") == "lastdb.run-v2-maintenance-approval.v3"
            and recorded.get("profile") == "run-v2-format4-auto-maintenance-v1"
            and recorded.get("mode") == "native-run-v2-ci"
            and recorded.get("source_git_oid") == recorded.get("accepted_main_commit") == SOURCE
            and recorded.get("baseline_source_git_oid") == BASELINE
            and recorded.get("baseline_programs_sha256") == BASELINE_PROGRAMS
            and recorded.get("baseline_writer_policy") == original["result"],
            "The original hashed approval does not bind this writer policy")
    for name in ("lastdb", "lastdbd"):
        candidate = recorded["candidate"][name]
        require(binding.get(name + "_sha256") == candidate["sha256"]
                and binding.get(name + "_version") == candidate["version"]
                and binding.get("candidate_cli" if name == "lastdb" else "candidate") == candidate["path"],
                "The original recovery candidate pair differs from its hashed approval")
    return recorded


def recovery(state, original, current):
    require(state.get("schema") == "lastdb.run-v2-maintenance-upgrade.v3"
            and state.get("phase") == "rolled-back", "The original program recovery did not finish")
    old, new = identity(original["observation"]["session"]), identity(current["session"])
    baseline, proof = state["baseline"], state["stop_proof"]
    require(baseline["session"] == state.get("last_stopped_session") == old
            and proof.get("receipt") == {"version": 1, **old, "flush_ok": True}
            and type(proof["receipt"].get("version")) is int and proof["receipt"].get("flush_ok") is True,
            "The original writer lacks its exact clean shutdown receipt")
    ended = proof["session"]
    require(all(ended.get(name) == value for name, value in old.items())
            and ended.get("exit") == "clean" and uint(ended.get("end_ts"), True) >= old["start_ts"]
            and new != old and new["start_ts"] >= ended["end_ts"],
            "The original clean session does not precede the recovered writer")
    pairs = baseline["pair"]
    require(set(pairs) == {"lastdb", "lastdbd"}
            and {name: item["sha256"] for name, item in pairs.items()} == BASELINE_PROGRAMS
            and baseline["plist_sha256"] == original["observation"]["launchd_plist"]["sha256"]
            and ended.get("build_version") == pairs["lastdbd"]["version"],
            "The program recovery changed the original pair or primary configuration")
    startup = state["startup_bindings"]["baseline"]
    intent, live = state["startup_intents"]["baseline"], state["live"]
    directory = str(Path(pairs["lastdbd"]["path"]).parent)
    require(startup["session"] == live["session"] == new and startup["directory"] == directory
            and intent == {"directory": directory, "previous_session": old}
            and live["health"]["version"] == pairs["lastdbd"]["version"]
            and live["health"]["native"]["writer_failed"] is False
            and live["health"].get("keyed_read") == baseline["keyed_read"],
            "The recovered writer is not the actual healthy baseline startup")
    return original_approval(state, original)


def check(approval):
    original = approved(approval)
    current_ref, recovery_ref = approval["current_writer_policy"], approval["baseline_recovery_state"]
    current, state = reference(current_ref, 65536), reference(recovery_ref, 262144)
    require(current.get("schema") == "lastdb.primary-writer-policy-observation.v1"
            and current.get("original_writer_policy") == original["result"]
            and current.get("recorded_program_recovery") == recovery_ref
            and current.get("source") == BASELINE and current.get("programs") == BASELINE_PROGRAMS
            and current.get("settings") == SETTINGS and current.get("effective_process_matches_plist") is True
            and type(current.get("primary_effects")) is int and current["primary_effects"] == 0,
            "The current writer observation changes the original ENB policy or recovery binding")
    plist = current.get("launchd_plist")
    require(isinstance(plist, dict) and set(plist) == {"path", "sha256"}
            and plist == original["observation"]["launchd_plist"]
            and plist["path"] == approval["launchd_plist"] and digest(plist["sha256"])
            and uint(current.get("observed_at"), True) >= current["session"]["start_ts"]
            and current["observed_at"] >= original["observation"]["observed_at"],
            "The recovered writer configuration or observation time differs")
    recovery(state, original, current)
    return {"original": original, "current": {"result": current_ref, "observation": current},
            "baseline_recovery_state": recovery_ref}


def initial(approval, baseline, plist):
    observed = check(approval)["current"]["observation"]
    require(baseline["session"] == observed["session"]
            and baseline["plist_sha256"] == observed["launchd_plist"]["sha256"]
            and {name: item["sha256"] for name, item in baseline["pair"].items()} == observed["programs"]
            and all(plist.get("EnvironmentVariables", {}).get(name) == value for name, value in SETTINGS.items()),
            "The initial primary pair, session, or configuration differs from its actual recovered writer")
