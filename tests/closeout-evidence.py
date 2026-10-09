#!/usr/bin/env python3
"""Filtered fixtures for the shared closeout evidence contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import types

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "lib" / "closeout_evidence.py"
PR = "https://github.com/EdgeVector/last-stack/pull/1001"


class Failure(Exception):
    pass


def equal(actual, expected, label):
    if actual != expected:
        raise Failure(f"{label}: expected {expected!r}, got {actual!r}")


def truth(actual, label):
    if not actual:
        raise Failure(label)


def load_module():
    # Read the actual source for each filtered probe. Timestamp-based bytecode
    # caches can hide a same-size mutation made within the same second.
    module = types.ModuleType("closeout_evidence_fixture")
    module.__file__ = str(LIB)
    exec(compile(LIB.read_bytes(), str(LIB), "exec"), module.__dict__)
    return module


def legacy(body):
    import re

    positive = re.compile(r"(?i)\b(pass|passed|verified|proven|green|satisfied|met|confirmed|success|successful|complete|completed)\b")
    lines = []
    for line in body.splitlines():
        match = re.match(r"(?i)^\s*(?:[-*]\s*)?PROOF\s*:\s*(.*?)\s*$", line)
        if match and positive.search(match.group(1)):
            lines.append(" ".join(match.group(1).split()))
    material = "closeout-v1\npr=" + PR + "\nproof=" + "\n".join(lines)
    return hashlib.sha256(material.encode()).hexdigest()


def parse(mod, body):
    return mod.parse_evidence(body, PR)


def case_latest_negative(mod):
    result = parse(mod, "PROOF: PASS old check\nPROOF: FAIL current check")
    equal(result["verdict"], "negative", "latest negative defeats old PASS")
    equal(result["evidence_line"], 2, "latest negative line")


def case_latest_positive(mod):
    result = parse(mod, "PROOF: FAIL old check\nPROOF: passed unit tests")
    equal(result["verdict"], "positive", "latest lowercase passed survives")
    equal(result["evidence"], "passed unit tests", "latest evidence payload")


def case_negative_words(mod):
    for word in ("END STATE unmet", "END STATE not met", "not verified", "unverified", "not satisfied", "incomplete", "did not pass", "never confirmed"):
        result = parse(mod, "PROOF: PASS old check\nPROOF: " + word)
        equal(result["verdict"], "negative", "negative words refuse: " + word)


def case_negative_not_met(mod):
    equal(parse(mod, "PROOF: END STATE not met; unit tests passed")["verdict"], "negative", "negative verdict defeats met and passed")


def case_pending(mod):
    result = parse(mod, "PROOF: PASS old check\nPROOF: pending live proof; unit tests passed")
    equal(result["verdict"], "pending", "pending defeats positive words")
    equal(parse(mod, "PROOF: END STATE not yet met")["verdict"], "pending", "not yet is pending")


def case_reopen_marker(mod):
    result = parse(mod, "PROOF: PASS old check\nPROOF[reopened-end-state-unmet]: old PASS is invalid")
    equal(result["verdict"], "negative", "exact reopen marker defeats old PASS")
    equal(result["evidence_line"], 2, "reopen marker line")


def case_outcome(mod):
    result = parse(mod, "## OUTCOME\nEND STATE is met.\n## OUTCOME\nEND STATE unmet.")
    equal(result["verdict"], "negative", "latest OUTCOME defeats old outcome")
    equal(result["evidence_line"], 4, "OUTCOME physical verdict line")
    equal(parse(mod, "OUTCOME: END STATE verified on the host")["verdict"], "positive", "inline OUTCOME format")
    equal(parse(mod, "## OUTCOME\nEND STATE:\nmet on the host")["verdict"], "positive", "multiline OUTCOME format")


def case_outcome_order(mod):
    body = "## OUTCOME\nEND STATE met.\nPROOF: PASS unit tests\nEND STATE failed on the host."
    equal(parse(mod, body)["verdict"], "negative", "later OUTCOME line defeats intervening PROOF")
    equal(parse(mod, "## OUTCOME\nEND STATE unmet.\nEND STATE verified now.")["verdict"], "positive", "later explicit outcome permits recovery")
    equal(parse(mod, "## OUTCOME\nEND STATE unmet.\nThe unit tests passed.")["verdict"], "negative", "unrelated unit result cannot replace explicit END STATE failure")


def case_desired_prose(mod):
    body = "## GOAL\nPass all checks.\n## END STATE\nThe helper is verified and the live state is met."
    result = parse(mod, body)
    equal(result["verdict"], "absent", "desired prose has no evidence authority")
    equal(result["end_state_required"], True, "END STATE remains required")
    equal(parse(mod, "PROOF: the check should pass after the future deploy")["verdict"], "error", "desired PROOF is not positive evidence")


def case_proof_in_end_state(mod):
    result = parse(mod, "## END STATE\nThe helper works.\n- PROOF: PASS live check at abc123")
    equal(result["verdict"], "positive", "explicit PROOF inside END STATE remains valid")
    equal(result["evidence_line"], 3, "END STATE proof line")


def case_fenced(mod):
    body = "PROOF: PASS live check\n```text\nPROOF: FAIL example\n## OUTCOME\nEND STATE unmet\n```"
    equal(parse(mod, body)["verdict"], "positive", "fenced examples have no authority")
    equal(parse(mod, "~~~\nPROOF: PASS example\n~~~")["verdict"], "absent", "tilde fence has no authority")


def case_quoted(mod):
    result = parse(mod, "PROOF: PASS live check\n> PROOF: FAIL quoted example")
    equal(result["verdict"], "positive", "quoted examples have no authority")
    body = "## OUTCOME\nEND STATE met on the host\n> END STATE failed in a quoted example"
    equal(parse(mod, body)["verdict"], "positive", "quoted OUTCOME examples have no authority")


def case_unknown(mod):
    result = parse(mod, "PROOF: PASS old check\nPROOF: evidence unavailable")
    equal(result["verdict"], "error", "unavailable explicit evidence refuses")
    equal(result["signal"], "", "parser error has no signal")
    truth(result["error"], "parser error has an explicit reason")


def case_unknown_receipt(mod):
    equal(parse(mod, "PROOF: opaque receipt abc")["verdict"], "error", "unrecognized explicit receipt is not positive")


def case_error_with_positive(mod):
    equal(parse(mod, "PROOF: ERROR live check; unit tests passed")["verdict"], "error", "explicit error defeats passed unit tests")
    equal(parse(mod, "PROOF: PASS unit tests; live proof unavailable")["verdict"], "error", "unavailable proof defeats unit PASS")


def case_done_when(mod):
    result = parse(mod, "DONE-WHEN:\nDONE-WHEN: file /tmp/proof matches /^PASS/\nPROOF: PASS unit tests\nDONE-WHEN: ignored later predicate")
    equal(result["done_when"], "file /tmp/proof matches /^PASS/", "first nonempty DONE-WHEN survives positive proof")
    equal(result["end_state_required"], True, "DONE-WHEN remains an independent gate")
    equal(result["verdict"], "positive", "predicate text does not alter evidence verdict")


def case_legacy_hash(mod):
    body = "PROOF: PASS first\n* PROOF: VERIFIED   second\nPROOF: END STATE not met"
    equal(parse(mod, body)["legacy_signal"], legacy(body), "exact historical hash includes old false-positive payload")
    equal(parse(mod, body)["verdict"], "negative", "historical hash grants no positive verdict")


def case_legacy_reopen(mod):
    body = "PROOF: PASS first\nPROOF: VERIFIED second"
    body += "\nCLOSEOUT-DECISION signal=" + legacy(body) + " state=closed"
    result = mod.parse_card_evidence({"body": body, "column": "doing"}, PR)
    equal(result["reopened_same_signal"], True, "legacy multi-proof marker cannot gain a new signal by parser change")
    equal(parse(mod, body)["reopened_same_signal"], False, "body-only parser cannot infer reopened column")


def case_legacy_replay(mod):
    prefix = "PROOF: PASS first\nPROOF: VERIFIED second"
    marked = prefix + "\nCLOSEOUT-DECISION signal=" + legacy(prefix) + " state=closed"
    replay = marked + "\nPROOF: VERIFIED second"
    truth(legacy(replay) != legacy(prefix), "legacy replay changes the aggregate historical hash")
    result = mod.parse_card_evidence({"body": replay, "column": "doing"}, PR)
    equal(result["reopened_same_signal"], True, "identical proof replay cannot evade a legacy marker")


def case_fresh_after_marker(mod):
    body = "PROOF: PASS first\nPROOF: VERIFIED second"
    body += "\nCLOSEOUT-DECISION signal=" + legacy(body) + " state=closed"
    before = mod.parse_card_evidence({"body": body, "column": "doing"}, PR)
    result = mod.parse_card_evidence({"body": body + "\nPROOF: VERIFIED fresh live check", "column": "doing"}, PR)
    equal(result["reopened_same_signal"], False, "fresh positive evidence after marker permits closeout")
    truth(result["signal"] != before["signal"], "fresh event changes signal")
    outcome = mod.parse_card_evidence({"body": body + "\n## OUTCOME\nEND STATE verified on the host", "column": "doing"}, PR)
    equal(outcome["reopened_same_signal"], False, "fresh OUTCOME after legacy marker permits closeout")


def case_new_marker(mod):
    body = "PROOF: PASS live check"
    signal = parse(mod, body)["signal"]
    marked = body + "\nCLOSEOUT-DECISION signal=" + signal + " state=closed"
    result = mod.parse_card_evidence({"body": marked, "column": "todo"}, PR)
    equal(result["reopened_same_signal"], True, "new marker refuses any non-done reopened column")
    equal(mod.parse_card_evidence({"body": marked, "column": "done"}, PR)["reopened_same_signal"], False, "done column is not reopened")
    equal(parse(mod, marked)["signal"], signal, "closeout marker does not alter event signal")


def case_latest_marker(mod):
    first = "PROOF: PASS first live check"
    body = first + "\nCLOSEOUT-DECISION signal=" + parse(mod, first)["signal"] + " state=closed"
    body += "\nPROOF: VERIFIED second live check"
    body += "\nCLOSEOUT-DECISION signal=" + parse(mod, body)["signal"] + " state=closed"
    equal(mod.parse_card_evidence({"body": body, "column": "doing"}, PR)["reopened_same_signal"], True, "latest matching marker owns the accepted claim")


def case_marker_identity(mod):
    body = "PROOF: PASS live check"
    signal = parse(mod, body)["signal"]
    marked = body + "\nCLOSEOUT-DECISION signal=" + signal + " state=closed"
    edited = "## GOAL\nAn unrelated clarification.\n" + marked
    result = mod.parse_card_evidence({"body": edited, "column": "doing"}, PR)
    equal(result["signal"], signal, "unrelated prefix does not invent new evidence")
    equal(result["reopened_same_signal"], True, "unrelated body edit keeps current reopen refusal")
    repeated = mod.parse_card_evidence({"body": marked + "\nPROOF: PASS live check", "column": "doing"}, PR)
    equal(repeated["reopened_same_signal"], True, "identical proof replay is not a new current signal")


def case_card_url_fallback(mod):
    body = "PROOF: PASS live check"
    signal = parse(mod, body)["signal"]
    marked = body + "\nCLOSEOUT-DECISION signal=" + signal + " state=closed"
    result = mod.parse_card_evidence({"body": marked, "column": "doing", "pr_url": PR}, "")
    equal(result["signal"], signal, "empty argument uses canonical Card PR URL")
    equal(result["reopened_same_signal"], True, "Card URL fallback preserves early reopen refusal")


def case_absent_signal(mod):
    result = parse(mod, "## END STATE\nThe helper works.")
    equal(result["verdict"], "absent", "ordinary absence preserves warning semantics")
    equal(len(result["signal"]), 64, "absent has deterministic non-authorizing signal")
    equal(result["signal"], parse(mod, "## END STATE\nThe helper works.")["signal"], "absent signal is deterministic")
    truth(result["signal"] != mod.parse_evidence("## END STATE\nThe helper works.", PR + "2")["signal"], "merged URL binds signal")


def case_bad_card(mod):
    for card in ({"body": []}, {"body": "PROOF: PASS", "column": []}, {"card": []}, []):
        equal(mod.parse_card_evidence(card, PR)["verdict"], "error", "malformed Card refuses")


def write_config(directory, value):
    path = Path(directory) / "slot.json"
    path.write_text(json.dumps(value), encoding="utf-8")
    return path


def refused(mod, path, label):
    try:
        mod.load_protected_card_keys(path)
    except (ValueError, OSError):
        return
    raise Failure(label)


def case_config_valid(mod):
    keys = ["factory-scoped-dispatch-20261008", "factory-guarded-closeout-20261008", "factory-canonical-active-counts-20261008", "factory-repair-controller-20261009"]
    with tempfile.TemporaryDirectory(prefix="closeout-evidence-config-") as directory:
        path = write_config(directory, {"version": 1, "protected_card_keys": keys})
        equal(mod.load_protected_card_keys(path), keys, "valid protected list preserves order")
        path = write_config(directory, {"version": 1, "protected_card_keys": ["valid_card--key"]})
        equal(mod.load_protected_card_keys(path), ["valid_card--key"], "public kanban slug grammar remains valid")


def case_config_version(mod):
    with tempfile.TemporaryDirectory(prefix="closeout-evidence-config-") as directory:
        for version in (True, 0, 2, "1", None):
            path = write_config(directory, {"version": version, "protected_card_keys": ["factory-card"]})
            refused(mod, path, "wrong config version refuses")


def case_config_keys(mod):
    with tempfile.TemporaryDirectory(prefix="closeout-evidence-config-") as directory:
        for keys in ([], "factory-card", ["factory-card", "factory-card"], ["factory-card", 1], ["../factory-card"], [" factory-card"], ["factory/card"], ["factory\ncard"]):
            path = write_config(directory, {"version": 1, "protected_card_keys": keys})
            refused(mod, path, "malformed protected list refuses")


def case_config_empty(mod):
    with tempfile.TemporaryDirectory(prefix="closeout-evidence-config-") as directory:
        refused(mod, write_config(directory, {"version": 1, "protected_card_keys": []}), "empty protected list refuses")


def case_config_duplicate(mod):
    with tempfile.TemporaryDirectory(prefix="closeout-evidence-config-") as directory:
        refused(mod, write_config(directory, {"version": 1, "protected_card_keys": ["factory-card", "factory-card"]}), "duplicate protected keys refuse")


def case_config_slug(mod):
    with tempfile.TemporaryDirectory(prefix="closeout-evidence-config-") as directory:
        refused(mod, write_config(directory, {"version": 1, "protected_card_keys": ["../factory-card"]}), "invalid canonical protected slug refuses")


def case_config_file(mod):
    with tempfile.TemporaryDirectory(prefix="closeout-evidence-config-") as directory:
        path = Path(directory) / "slot.json"
        refused(mod, path, "missing config refuses")
        path.write_text('{"version":1,"protected_card_keys":', encoding="utf-8")
        refused(mod, path, "malformed JSON config refuses")
        path.write_text('{"version":1,"version":1,"protected_card_keys":["factory-card"]}', encoding="utf-8")
        refused(mod, path, "duplicate config fields refuse")


def run_cli(mode, card, extra=()):
    env = dict(os.environ, CARD_JSON=json.dumps(card), EFFECTIVE_PR_URL=PR)
    return subprocess.run([sys.executable, str(LIB), "--mode", mode, *extra], env=env, text=True, capture_output=True, timeout=10)


def assignments(output):
    # The parser emits shlex-quoted shell assignments. POSIX shell parses them;
    # this fixture reads the assignments without eval or execution.
    values = {}
    for token in shlex.split(output):
        key, value = token.split("=", 1)
        values[key] = value
    return values


def case_cli_end_state(mod):
    card = {"body": "DONE-WHEN: file /tmp/a matches /^PASS/\nPROOF: PASS live check; literal $(touch /tmp/unwanted) 'quoted'", "column": "doing"}
    proc = run_cli("end-state", {"card": card})
    equal(proc.returncode, 0, "end-state CLI succeeds")
    values = assignments(proc.stdout)
    equal(values["proof_verdict"], "positive", "CLI shares positive verdict")
    equal(values["proof_evidence_line"], "2", "CLI reports physical line")
    truth(values["done_when_b64"], "CLI retains predicate encoding")
    equal(values["closeout_initial_column"], "doing", "CLI unwraps canonical Card")


def case_cli_deploy(mod):
    card = {"repo": "EdgeVector/last-stack", "tags": ["awaiting-deploy"], "body": "Requires-Deploy: host-track, loom host-track\n## END STATE\nThe installed helper cutover works.\nPROOF: PASS old check\nPROOF: pending current host proof"}
    proc = run_cli("deploy", card)
    equal(proc.returncode, 0, "deploy CLI succeeds")
    values = assignments(proc.stdout)
    equal(values["deploy_repo"], "last-stack", "deploy repo name")
    equal(values["deploy_reqs"], "host-track\nloom", "deploy requirements retain unique order")
    equal(values["parked_tag"], "1", "deploy parked tag")
    equal(values["helper_cutover_end_state"], "1", "helper cutover END STATE")
    equal(values["positive_proof"], "0", "deploy mode refuses pending after old PASS")


def case_cli_error(mod):
    proc = run_cli("end-state", {"body": [], "column": "doing"})
    truth(proc.returncode != 0, "malformed Card CLI exits nonzero")
    values = assignments(proc.stdout)
    equal(values["proof_verdict"], "error", "CLI emits an explicit error verdict")
    equal(values["closeout_signal"], "", "CLI error signal is empty")
    truth(values["proof_error"], "CLI error has a reason")


def case_shell_quote(mod):
    import contextlib
    import io

    literal = "$(printf admitted); literal 'quote'\nsecond"
    capture = io.StringIO()
    with contextlib.redirect_stdout(capture):
        mod._emit_shell({"fixture_value": literal})
    script = capture.getvalue() + 'printf "%s" "$fixture_value"'
    proc = subprocess.run(["/bin/sh", "-c", script], text=True, capture_output=True, timeout=10)
    equal(proc.returncode, 0, "quoted assignments remain valid shell")
    equal(proc.stdout, literal, "shell quoting preserves literal data")


def case_cli_json(mod):
    proc = run_cli("verdict", {"body": "PROOF: PASS current check", "column": "doing"})
    equal(proc.returncode, 0, "verdict CLI succeeds")
    equal(json.loads(proc.stdout)["verdict"], "positive", "verdict CLI uses shared parser")
    with tempfile.TemporaryDirectory(prefix="closeout-evidence-config-") as directory:
        path = write_config(directory, {"version": 1, "protected_card_keys": ["factory-card"]})
        proc = run_cli("exclusions", {}, ("--config", str(path)))
        equal(proc.returncode, 0, "exclusions CLI succeeds")
        equal(json.loads(proc.stdout)["protected_card_keys"], ["factory-card"], "exclusions CLI shares config list")
        proc = run_cli("exclusions", {}, ("--config", str(Path(directory) / "missing")))
        truth(proc.returncode != 0, "exclusions CLI refuses missing config")


def case_finite_card(mod):
    env = dict(os.environ, FACTORY_CONTRACT_JSON=json.dumps({"version": 1, "result": "ok", "contract_sha256": "a" * 64, "protected_card_keys": ["factory-card"]}))
    for slug, expected in (("factory-card", "1"), ("ordinary-card", "0")):
        env["CARD_JSON"] = json.dumps({"card": {"slug": slug, "body": "", "column": "doing"}})
        proc = subprocess.run([sys.executable, str(LIB), "--mode", "finite-card", "--slug", slug], env=env, text=True, capture_output=True, timeout=10)
        equal(proc.returncode, 0, "finite-card CLI succeeds with valid envelope")
        equal(assignments(proc.stdout)["factory_excluded"], expected, "finite-card exact membership")
    for envelope in ({"version": 1, "result": "error", "protected_card_keys": ["factory-card"]}, {"version": True, "result": "ok", "protected_card_keys": ["factory-card"]}, {"version": 1, "result": "ok", "protected_card_keys": []}, {"version": 1, "result": "ok", "protected_card_keys": ["factory-card", "factory-card"]}):
        envelope["contract_sha256"] = "a" * 64
        env["FACTORY_CONTRACT_JSON"] = json.dumps(envelope)
        proc = subprocess.run([sys.executable, str(LIB), "--mode", "finite-card", "--slug", "ordinary-card"], env=env, text=True, capture_output=True, timeout=10)
        truth(proc.returncode != 0, "invalid contract envelope refuses finite-card")
    env["FACTORY_CONTRACT_JSON"] = json.dumps({"version": 1, "result": "ok", "contract_sha256": "a" * 64, "protected_card_keys": ["factory-card"]})
    for card in ({}, {"slug": []}, {"slug": "../factory-card"}, {"slug": "factory-card", "body": []}):
        env["CARD_JSON"] = json.dumps(card)
        proc = subprocess.run([sys.executable, str(LIB), "--mode", "finite-card", "--slug", "factory-card"], env=env, text=True, capture_output=True, timeout=10)
        truth(proc.returncode != 0, "malformed canonical Card refuses finite-card")


def case_finite_requested_slug(mod):
    env = dict(os.environ, FACTORY_CONTRACT_JSON=json.dumps({"version": 1, "result": "ok", "contract_sha256": "a" * 64, "protected_card_keys": ["factory-card"]}), CARD_JSON=json.dumps({"slug": "factory-card", "body": "", "column": "doing"}))
    proc = subprocess.run([sys.executable, str(LIB), "--mode", "finite-card"], env=env, text=True, capture_output=True, timeout=10)
    truth(proc.returncode != 0, "finite-card requires the original requested slug")
    proc = subprocess.run([sys.executable, str(LIB), "--mode", "finite-card", "--slug", "ordinary-card"], env=env, text=True, capture_output=True, timeout=10)
    truth(proc.returncode != 0, "finite-card refuses a foreign canonical Card")


def case_finite_foreign_card(mod):
    env = dict(os.environ, FACTORY_CONTRACT_JSON=json.dumps({"version": 1, "result": "ok", "contract_sha256": "a" * 64, "protected_card_keys": ["factory-card"]}), CARD_JSON=json.dumps({"slug": "ordinary-card", "body": "", "column": "doing"}))
    proc = subprocess.run([sys.executable, str(LIB), "--mode", "finite-card", "--slug", "factory-card"], env=env, text=True, capture_output=True, timeout=10)
    truth(proc.returncode != 0, "protected request refuses a foreign ordinary Card")


def finite_cli(envelope):
    env = dict(os.environ, FACTORY_CONTRACT_JSON=json.dumps(envelope), CARD_JSON=json.dumps({"slug": "ordinary-card", "body": "", "column": "doing"}))
    return subprocess.run([sys.executable, str(LIB), "--mode", "finite-card", "--slug", "ordinary-card"], env=env, text=True, capture_output=True, timeout=10)


def case_finite_contract_sha(mod):
    envelope = {"version": 1, "result": "ok", "protected_card_keys": ["factory-card"]}
    proc = finite_cli(envelope)
    truth(proc.returncode != 0, "finite contract refuses missing SHA64")
    for value in (None, True, [], 123, "", "a" * 63, "a" * 65, "g" * 64, "A" * 64, "a" * 64 + "\n"):
        envelope["contract_sha256"] = value
        proc = finite_cli(envelope)
        truth(proc.returncode != 0, "finite contract refuses malformed SHA64")
    envelope["contract_sha256"] = "0123456789abcdef" * 4
    equal(finite_cli(envelope).returncode, 0, "finite contract accepts canonical SHA64")


def case_finite_contract_cap(mod):
    envelope = {"version": 1, "result": "ok", "contract_sha256": "a" * 64, "protected_card_keys": [f"factory-card-{n}" for n in range(257)]}
    proc = finite_cli(envelope)
    truth(proc.returncode != 0, "finite contract refuses 257 keys")


def case_finite_contract_limit(mod):
    envelope = {"version": 1, "result": "ok", "contract_sha256": "a" * 64, "protected_card_keys": [f"factory-card-{n}" for n in range(256)]}
    proc = finite_cli(envelope)
    equal(proc.returncode, 0, "finite contract accepts 256 distinct keys")
    equal(assignments(proc.stdout)["factory_excluded"], "0", "finite contract limit preserves exact membership")


CASES = {name.removeprefix("case_").replace("_", "-"): fn for name, fn in list(globals().items()) if name.startswith("case_")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=sorted(CASES))
    args = parser.parse_args()
    module = load_module()
    selected = [args.case] if args.case else list(CASES)
    for name in selected:
        try:
            CASES[name](module)
        except Exception as exc:
            print(f"FAIL: {name}: {exc}", file=sys.stderr)
            return 1
        print(f"PASS: {name}")
    print(f"ok closeout-evidence cases={len(selected)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
