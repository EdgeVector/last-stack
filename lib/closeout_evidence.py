#!/usr/bin/env python3
"""One explicit-evidence parser for closeout and the finite factory contract.

A signal identifies evidence. It does not establish merge, deploy, or a
DONE-WHEN predicate. The closeout consumers keep those independent gates.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import sys

_POSITIVE = re.compile(r"\b(pass|passed|verified|proven|green|satisfied|met|confirmed|success|successful|complete|completed|holds|measured)\b", re.I)
_LEGACY_POSITIVE = re.compile(r"\b(pass|passed|verified|proven|green|satisfied|met|confirmed|success|successful|complete|completed)\b", re.I)
_PENDING = re.compile(r"\b(pending|deferred|blocked|awaiting|not\s+yet)\b", re.I)
_ERROR = re.compile(r"^(?:error|unavailable|unknown|inconclusive)\b|\b(?:evidence|proof|check|state)\s+(?:is\s+)?(?:unavailable|unknown|inconclusive)\b", re.I)
_NEGATIVE = re.compile(r"\b(fail|failed|failure|unmet|unverified|unsatisfied|incomplete|rejected|false)\b|\b(?:not|never|did\s+not|does\s+not|is\s+not|was\s+not)\s+(?:pass|passed|verified|proven|green|satisfied|met|confirmed|successful|complete|completed|true|hold|holds)\b", re.I)
_DESIRED = re.compile(r"\b(should|must|will|would|could|expected|desired|planned)\b", re.I)
_TARGET = re.compile(r"\bEND[ \t]+STATE\b|\bDONE-WHEN\b", re.I)
_PROOF = re.compile(r"^\s*(?:[-*]\s*)?PROOF\s*:\s*(.*?)\s*$", re.I)
_REOPEN = re.compile(r"^\s*(?:[-*]\s*)?PROOF\[reopened-end-state-unmet\]\s*:\s*(.*?)\s*$", re.I)
_OUTCOME = re.compile(r"^\s*(?:[-*]\s*)?OUTCOME\s*:\s*(.*?)\s*$", re.I)
_HEADING = re.compile(r"^ {0,3}(#{1,6})[ \t]+(.*)$")
_DONE_WHEN = re.compile(r"^\s*DONE-WHEN\s*:\s*(.*?)\s*$", re.I)
_CLOSED_MARKER = re.compile(r"^\s*CLOSEOUT-DECISION\s+signal=([0-9a-f]{64})\s+state=closed\b", re.I)
_SLUG = re.compile(r"[a-z0-9][a-z0-9_-]*\Z")


def _normalize(text):
    return " ".join(text.split())


def _visible_lines(body):
    """Keep physical line numbers; examples cannot supply evidence."""
    fence = None
    for number, line in enumerate(body.splitlines(), 1):
        match = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence is not None:
            if match and match.group(1)[0] == fence[0] and len(match.group(1)) >= fence[1] and not match.group(2).strip():
                fence = None
            continue
        if match:
            fence = (match.group(1)[0], len(match.group(1)))
            continue
        if re.match(r"^\s*>", line):
            continue
        yield number, line


def _classify(payload):
    # "not yet met" is a pending claim, while "not met" is negative.
    without_not_yet = re.sub(r"\bnot\s+yet\s+(?:met|verified|complete|completed|satisfied|confirmed|passed)\b", "pending", payload, flags=re.I)
    if _NEGATIVE.search(without_not_yet):
        return "negative"
    if _PENDING.search(payload):
        return "pending"
    if _ERROR.search(payload):
        return "error"
    if _DESIRED.search(payload):
        return None
    if _POSITIVE.search(payload):
        return "positive"
    return None


def _legacy_signal(body, pr_url):
    # This deliberately reproduces the old parser, including its negatives
    # and examples. It is used only to refuse a historical re-close.
    proofs = []
    for line in body.splitlines():
        match = _PROOF.match(line)
        if match and _LEGACY_POSITIVE.search(match.group(1)):
            proofs.append(_normalize(match.group(1)))
    material = "closeout-v1\npr=" + pr_url + "\nproof=" + "\n".join(proofs)
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _legacy_marker_signals(body, pr_url):
    # Snapshot the historical hash at each marker, in one pass. A later proof
    # changes the full-body old hash but cannot erase the marker's identity.
    state = hashlib.sha256(("closeout-v1\npr=" + pr_url + "\nproof=").encode("utf-8"))
    first = True
    prefixes = {}
    for number, line in enumerate(body.splitlines(), 1):
        if _CLOSED_MARKER.match(line):
            prefixes[number] = state.hexdigest()
        match = _PROOF.match(line)
        if match and _LEGACY_POSITIVE.search(match.group(1)):
            text = ("" if first else "\n") + _normalize(match.group(1))
            state.update(text.encode("utf-8"))
            first = False
    return prefixes


def _event_signal(event, pr_url):
    _, kind, verdict, evidence = event
    material = json.dumps({"version": 2, "pr": pr_url, "event": kind, "verdict": verdict, "evidence": evidence}, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "" if verdict == "error" else hashlib.sha256(material.encode("utf-8")).hexdigest()


def _error_result(reason):
    return {
        "verdict": "error", "evidence": "", "evidence_line": 0,
        "signal": "", "legacy_signal": "", "done_when": "",
        "reopened_same_signal": False, "end_state_required": False,
        "error": reason, "previous_signal": "", "column": "",
    }


def _parse(body, pr_url):
    if not isinstance(body, str) or not isinstance(pr_url, str):
        return _error_result("evidence-input-not-string"), []
    events = []
    markers = []
    done_when = ""
    end_state_required = False
    outcome_section = False
    outcome_target = False
    legacy_prefixes = _legacy_marker_signals(body, pr_url)
    for number, line in _visible_lines(body):
        marker = _CLOSED_MARKER.match(line)
        if marker:
            prefix_event = events[-1] if events else (0, "absent", "absent", "")
            markers.append((number, marker.group(1).lower(), _event_signal(prefix_event, pr_url), legacy_prefixes[number]))
            continue
        predicate = _DONE_WHEN.match(line)
        if predicate:
            end_state_required = True
            if not done_when and predicate.group(1):
                done_when = predicate.group(1)
            continue
        heading = _HEADING.match(line)
        if heading and len(heading.group(1)) <= 2:
            title = heading.group(2)
            if re.match(r"END[ \t]+STATE\b", title, re.I):
                end_state_required = True
            outcome_section = bool(re.match(r"OUTCOME\b", title, re.I))
            outcome_target = False
            if outcome_section:
                line = re.sub(r"^OUTCOME\b\s*:?[ \t]*", "", title, flags=re.I)
            else:
                continue
        reopened = _REOPEN.match(line)
        if reopened:
            events.append((number, "reopen", "negative", _normalize(reopened.group(1))))
            continue
        proof = _PROOF.match(line)
        if proof:
            payload = _normalize(proof.group(1))
            events.append((number, "proof", _classify(payload) or "error", payload))
            continue
        outcome = _OUTCOME.match(line)
        if outcome:
            payload = _normalize(outcome.group(1))
            if _TARGET.search(payload):
                events.append((number, "outcome", _classify(payload) or "error", payload))
            continue
        if outcome_section:
            if _TARGET.search(line):
                outcome_target = True
            verdict = _classify(line)
            if outcome_target and verdict is not None:
                events.append((number, "outcome", verdict, _normalize(line)))
                outcome_target = False
            elif outcome_target and re.search(r"\b(unavailable|unknown|error|inconclusive)\b", line, re.I):
                events.append((number, "outcome", "error", _normalize(line)))
                outcome_target = False
    event = events[-1] if events else (0, "absent", "absent", "")
    number, kind, verdict, evidence = event
    signal = _event_signal(event, pr_url)
    result = {
        "verdict": verdict, "evidence": evidence, "evidence_line": number,
        "signal": signal, "legacy_signal": _legacy_signal(body, pr_url),
        "done_when": done_when, "reopened_same_signal": False,
        "end_state_required": end_state_required,
        "error": "explicit-evidence-unrecognized" if verdict == "error" else "",
        "previous_signal": markers[-1][1] if markers else "", "column": "",
    }
    return result, markers


def parse_evidence(body, pr_url):
    """Return the latest explicit claim; no column or external gate is inferred."""
    return _parse(body, pr_url)[0]


def _unwrap_card(raw):
    if not isinstance(raw, dict):
        raise ValueError("card-not-object")
    if "card" in raw:
        if not isinstance(raw["card"], dict):
            raise ValueError("card-envelope-not-object")
        raw = raw["card"]
    for field in ("body", "column", "pr_url", "repo"):
        if field in raw and not isinstance(raw[field], str):
            raise ValueError("card-" + field.replace("_", "-") + "-not-string")
    return raw


def parse_card_evidence(card, pr_url):
    """Add canonical Card column/URL and historical reopen refusal."""
    try:
        card = _unwrap_card(card)
        if not isinstance(pr_url, str):
            raise ValueError("evidence-pr-url-not-string")
        effective_url = pr_url.strip() or card.get("pr_url", "").strip()
        result, markers = _parse(card.get("body", ""), effective_url)
        column = card.get("column", "")
        result["column"] = column
        matching = [marker for marker in markers if marker[1] in (marker[2], marker[3])]
        if matching:
            marker_line, marker_signal, prefix_signal, _ = matching[-1]
            fresh_positive = result["verdict"] == "positive" and result["evidence_line"] > marker_line and result["signal"] != prefix_signal
            result["previous_signal"] = marker_signal
            result["reopened_same_signal"] = column != "done" and not fresh_positive
        return result
    except (TypeError, ValueError) as exc:
        return _error_result(str(exc))


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate-json-field:" + key)
        value[key] = item
    return value


def _json(text):
    return json.loads(text, object_pairs_hook=_unique_object)


def _protected_keys(value, require_result=False):
    if not isinstance(value, dict):
        raise ValueError("factory-exclusions-not-object")
    if type(value.get("version")) is not int or value["version"] != 1:
        raise ValueError("factory-exclusions-version")
    if require_result and value.get("result") != "ok":
        raise ValueError("factory-contract-not-ok")
    if require_result:
        digest = value.get("contract_sha256")
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            raise ValueError("factory-contract-invalid-sha256")
    keys = value.get("protected_card_keys")
    if not isinstance(keys, list) or not keys:
        raise ValueError("factory-exclusions-empty-or-not-array")
    if require_result and len(keys) > 256:
        raise ValueError("factory-contract-key-cap")
    if any(not isinstance(key, str) or _SLUG.fullmatch(key) is None for key in keys):
        raise ValueError("factory-exclusions-invalid-slug")
    if len(keys) != len(set(keys)):
        raise ValueError("factory-exclusions-duplicate-key")
    return list(keys)


def load_protected_card_keys(configPath):
    """Read the sole source list. Artifact identity remains a consumer gate."""
    return _protected_keys(_json(Path(configPath).read_text(encoding="utf-8")))


def _deploy_values(card, result):
    body = card.get("body", "")
    repo = card.get("repo", "")
    if not repo:
        match = re.search(r"(?im)^\s*Repo:\s*(\S+)\s*$", body)
        repo = match.group(1) if match else ""
    requires = []
    section = []
    in_end = False
    for _, line in _visible_lines(body):
        match = re.match(r"^\s*Requires-Deploy:\s*(.+?)\s*$", line)
        if match:
            for item in re.split(r"[, ]+", match.group(1)):
                if item and item not in requires:
                    requires.append(item)
        heading = re.match(r"^##[ \t]+", line)
        if heading:
            in_end = bool(re.match(r"^##[ \t]+END[ \t]+STATE\b", line, re.I))
        if in_end or _DONE_WHEN.match(line):
            section.append(line)
    tags = card.get("tags", [])
    if isinstance(tags, str):
        tags = [tag for tag in re.split(r"[,\s]+", tags) if tag]
    if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags):
        raise ValueError("card-tags-not-string-array")
    parked = {"awaiting-deploy", "live-proof", "deploy-gate", "needs-safe-upgrade", "awaiting-validation"}
    cutover = re.compile(r"\b(helper[ -]?cutover|host-track|live\s+scheduled[- ]fire|installed\s+(?:helper|binary|cli)|safe-upgrade|awaiting-deploy)\b", re.I)
    return {
        "deploy_repo": repo.rsplit("/", 1)[-1], "deploy_reqs": "\n".join(requires),
        "parked_tag": int(any(tag.strip().lower() in parked for tag in tags)),
        "helper_cutover_end_state": int(bool(cutover.search("\n".join(section)))),
        "positive_proof": int(result["verdict"] == "positive" and not result["reopened_same_signal"]),
        "proof_verdict": result["verdict"], "proof_error": result["error"],
        "reopened_same_signal": int(result["reopened_same_signal"]),
    }


def _end_state_values(result):
    return {
        "end_state_required": int(result["end_state_required"]),
        "end_state_claimed": int(result["verdict"] == "positive"),
        "done_when_b64": base64.b64encode(result["done_when"].encode("utf-8")).decode("ascii"),
        "closeout_initial_column": result["column"],
        "closeout_previous_signal": result["previous_signal"],
        "closeout_signal": result["signal"], "legacy_signal": result["legacy_signal"],
        "proof_verdict": result["verdict"], "proof_evidence_line": result["evidence_line"],
        "reopened_same_signal": int(result["reopened_same_signal"]), "proof_error": result["error"],
    }


def _emit_shell(values):
    for key, value in values.items():
        print(key + "=" + shlex.quote(str(value)))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=("deploy", "end-state", "exclusions", "verdict", "finite-card"))
    parser.add_argument("--config", type=Path, default=Path(__file__).resolve().parents[1] / "config" / "factory-repair-slot.json")
    parser.add_argument("--slug", help="Original public Card key; required for finite-card mode")
    args = parser.parse_args(argv)
    try:
        if args.mode == "exclusions":
            print(json.dumps({"version": 1, "result": "ok", "protected_card_keys": load_protected_card_keys(args.config)}, sort_keys=True))
            return 0
        raw = _json(os.environ.get("CARD_JSON", "{}"))
        if args.mode == "finite-card":
            if not isinstance(args.slug, str) or _SLUG.fullmatch(args.slug) is None:
                raise ValueError("requested-card-slug-missing-or-invalid")
            keys = _protected_keys(_json(os.environ.get("FACTORY_CONTRACT_JSON", "")), require_result=True)
            card = _unwrap_card(raw)
            slug = card.get("slug")
            if not isinstance(slug, str) or _SLUG.fullmatch(slug) is None:
                raise ValueError("card-slug-invalid")
            if slug != args.slug:
                raise ValueError("canonical-card-slug-mismatch")
            _emit_shell({"factory_excluded": int(args.slug in keys)})
            return 0
        result = parse_card_evidence(raw, os.environ.get("EFFECTIVE_PR_URL", ""))
        if args.mode == "verdict":
            print(json.dumps(result, sort_keys=True))
        elif args.mode == "end-state":
            _emit_shell(_end_state_values(result))
        else:
            if result["verdict"] == "error":
                _emit_shell({"positive_proof": 0, "proof_verdict": "error", "proof_error": result["error"], "reopened_same_signal": 0})
            else:
                _emit_shell(_deploy_values(_unwrap_card(raw), result))
        return 1 if result["verdict"] == "error" else 0
    except (OSError, TypeError, ValueError) as exc:
        reason = str(exc)
        if args.mode in ("verdict", "exclusions"):
            print(json.dumps(_error_result(reason) if args.mode == "verdict" else {"version": 1, "result": "error", "error": reason}, sort_keys=True))
        elif args.mode == "finite-card":
            _emit_shell({"factory_excluded": 1, "proof_error": reason})
        elif args.mode == "end-state":
            _emit_shell(_end_state_values(_error_result(reason)))
        else:
            _emit_shell({"positive_proof": 0, "proof_verdict": "error", "proof_error": reason, "reopened_same_signal": 0})
        print("closeout-evidence: " + reason, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
