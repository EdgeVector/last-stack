#!/usr/bin/env bash
# Deterministic steps for lastdb-canary-release. Default stand-in (CI / proof).
# LOOM_LIVE=1 or LOOM_CANARY_LIVE=1 calls the real build / safe-upgrade / soak
# helpers. Never decides GREEN in an LLM.
set -euo pipefail
step="${1:?step name required}"

python3 - "$step" <<'PY'
import hashlib, json, os, re, subprocess, sys

step = sys.argv[1]
raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

live = os.environ.get("LOOM_CANARY_LIVE") == "1" or os.environ.get("LOOM_LIVE") == "1"
attempt = ctx.get("attempt") or 0
try:
    attempt = int(attempt)
except (TypeError, ValueError):
    attempt = 0
max_attempts = ctx.get("max_attempts") or 3
try:
    max_attempts = int(max_attempts)
except (TypeError, ValueError):
    max_attempts = 3


def emit(payload, line="PASS"):
    print("LOOM_CONTEXT_PATCH:" + json.dumps(payload, separators=(",", ":")))
    print(line)
    print("PASS")


def exhausted():
    return attempt >= max_attempts


def next_revision(name):
    current = ctx.get(name) or 0
    try:
        current = int(current)
    except (TypeError, ValueError):
        current = 0
    return current + 1


def exact_candidate_version(path):
    proc = subprocess.run(
        [path, "--version"], capture_output=True, text=True, timeout=15
    )
    fields = (proc.stdout or "").strip().split()
    if proc.returncode != 0 or not fields:
        raise RuntimeError(f"candidate version is unreadable: {path}")
    return fields[-1]


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def exact_upgrade_job(candidate, source_git_oid, claimed_version):
    daemon = os.path.realpath(candidate)
    cli = os.path.realpath(os.path.join(os.path.dirname(daemon), "lastdb"))
    if not re.fullmatch(r"[0-9a-f]{40}", source_git_oid):
        raise RuntimeError("candidate source Git OID is not one full lowercase commit")
    if not os.path.isfile(daemon) or not os.access(daemon, os.X_OK):
        raise RuntimeError(f"candidate lastdbd is not executable: {daemon}")
    if not os.path.isfile(cli) or not os.access(cli, os.X_OK):
        raise RuntimeError(f"candidate sibling lastdb is not executable: {cli}")
    if os.path.dirname(cli) != os.path.dirname(daemon) or os.path.basename(cli) != "lastdb":
        raise RuntimeError("candidate sibling lastdb is not a real file beside lastdbd")
    daemon_version = exact_candidate_version(daemon)
    cli_version = exact_candidate_version(cli)
    if daemon_version != cli_version:
        raise RuntimeError(
            f"candidate pair version mismatch: lastdbd={daemon_version} lastdb={cli_version}"
        )
    if claimed_version and claimed_version != daemon_version:
        raise RuntimeError(
            f"candidate version changed after build: expected={claimed_version} actual={daemon_version}"
        )
    daemon_sha = file_sha256(daemon)
    cli_sha = file_sha256(cli)
    artifact_digest = hashlib.sha256(
        "\0".join(
            [
                source_git_oid,
                daemon,
                cli,
                daemon_sha,
                cli_sha,
                daemon_version,
                cli_version,
            ]
        ).encode()
    ).hexdigest()
    return {
        "candidate": daemon,
        "candidate_cli": cli,
        "source_git_oid": source_git_oid,
        "version": daemon_version,
        "lastdbd_version": daemon_version,
        "lastdb_version": cli_version,
        "lastdbd_sha256": daemon_sha,
        "lastdb_sha256": cli_sha,
        "candidate_artifact_digest": artifact_digest,
        "safe_upgrade_protocol_version": "6",
    }


if not live:
    if step == "RECOVER_LIVE":
        oid = str(ctx.get("recovery_source_git_oid") or "stand-in")
        version = str(ctx.get("recovery_version") or oid)
        candidate = str(ctx.get("recovery_candidate") or "/tmp/stand-in-lastdbd")
        emit(
            {
                "candidate": candidate,
                "source_git_oid": oid,
                "version": version,
                "child_status": "green",
                "recovery_verified": True,
                "recovery_no_mutation": True,
                "last_note": "verified already-live candidate; no build or cutover",
            },
            "canary-step RECOVER_LIVE stand-in",
        )
    elif step == "BUILD_START":
        emit(
            {
                "build_next": "BUILD_COLLECT",
                "attempt": attempt,
                "max_attempts": max_attempts,
            },
            "canary-step BUILD_START stand-in",
        )
    elif step == "BUILD_POLL":
        emit(
            {
                "build_next": "BUILD_COLLECT",
                "build_poll_revision": next_revision("build_poll_revision"),
            },
            "canary-step BUILD_POLL stand-in",
        )
    elif step == "BUILD_COLLECT":
        oid = str(ctx.get("main_oid") or "stand-in")
        job = {
            "candidate": "/tmp/stand-in-lastdbd",
            "candidate_cli": "/tmp/lastdb",
            "source_git_oid": oid,
            "version": "stand-in",
            "lastdbd_version": "stand-in",
            "lastdb_version": "stand-in",
            "lastdbd_sha256": "stand-in",
            "lastdb_sha256": "stand-in",
            "candidate_artifact_digest": "stand-in",
            "safe_upgrade_protocol_version": "6",
        }
        emit(
            {
                **job,
                "upgrade_jobs": [job],
                "build_next": "CALL_A",
                "soak_started_at": "",
            },
            "canary-step BUILD_COLLECT stand-in",
        )
    elif step == "READ_A":
        emit({"child_status": "green"}, "canary-step READ_A stand-in child_status=green")
    elif step == "LEDGER":
        oid = str(ctx.get("source_git_oid") or ctx.get("main_oid") or "stand-in")
        version = str(ctx.get("version") or oid)
        emit(
            {
                "phase_next": "SOAK",
                "ledger_sha": version,
                "source_git_oid": oid,
                "version": version,
                "last_note": f"dogfood ledger recorded sha={version}",
            },
            "canary-step LEDGER stand-in",
        )
    elif step == "PROBE":
        forced = os.environ.get("CANARY_LOOM_PROBE_VERDICT") or ""
        verdict = forced or "green"
        if exhausted() and verdict == "red":
            verdict = "exhausted"
        emit({"verdict": verdict}, f"canary-step PROBE stand-in verdict={verdict}")
    elif step == "CUTOVER":
        print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"stand-in-cutover"}')
        print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"stand-in-cutover"}')
        emit({"cutover": "stand-in"}, "canary-step CUTOVER stand-in")
    elif step == "VERIFY":
        emit({"verify": "stand-in"}, "canary-step VERIFY stand-in")
    elif step == "SOAK":
        soak = os.environ.get("CANARY_LOOM_SOAK_STATUS") or "green"
        emit(
            {
                "soak_status": soak,
                "soak_hours": 24,
                "soak_poll_revision": next_revision("soak_poll_revision"),
            },
            f"canary-step SOAK stand-in status={soak}",
        )
    elif step == "RETRY_PREP":
        nxt = attempt + 1
        heal_status = str(ctx.get("heal_status") or "")
        if heal_status in ("blocked", "noop"):
            verdict = "blocked" if heal_status == "blocked" else "idle"
        elif nxt >= max_attempts:
            verdict = "exhausted"
        else:
            verdict = "red"
        emit(
            {"attempt": nxt, "verdict": verdict, "build_next": "BUILD_COLLECT"},
            f"canary-step RETRY_PREP stand-in attempt={nxt} verdict={verdict}",
        )
    elif step == "PROMOTE":
        print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"stand-in-promote"}')
        print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"stand-in-promote"}')
        emit({"promote": "stand-in"}, "canary-step PROMOTE stand-in")
    else:
        print(f"canary-step: unknown step {step}", file=sys.stderr)
        sys.exit(2)
    raise SystemExit(0)

# --- live path: wrap existing helpers; translate SM patches ---
def run(argv, timeout=120):
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError as e:
        print(f"canary-step: missing {argv[0]}: {e}", file=sys.stderr)
        sys.exit(2)
    except subprocess.TimeoutExpired:
        print(f"canary-step: timeout {argv}", file=sys.stderr)
        sys.exit(1)
    return p


def translate_sm(stdout):
    merged = {}
    for line in (stdout or "").splitlines():
        if line.startswith("SM_CONTEXT_PATCH:"):
            raw_patch = line[len("SM_CONTEXT_PATCH:") :]
            try:
                merged.update(json.loads(raw_patch))
            except json.JSONDecodeError:
                pass
        else:
            print(line)
    return merged


def recovery_fail(message):
    print(f"canary-step RECOVER_LIVE refused: {message}", file=sys.stderr)
    raise SystemExit(1)


def required_recovery_text(name):
    value = ctx.get(name)
    if not isinstance(value, str) or not value.strip():
        recovery_fail(f"missing {name}")
    return value.strip()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def binary_version(path, label):
    p = run([path, "--version"], timeout=30)
    if p.returncode != 0:
        recovery_fail(f"{label} --version failed rc={p.returncode}")
    fields = p.stdout.strip().split()
    if len(fields) < 2:
        recovery_fail(f"{label} returned an invalid version line")
    return fields[-1]


def parse_loom_show(text):
    values = {}
    nodes = set()
    for line in text.splitlines():
        if line.startswith("status: "):
            values["status"] = line.split(": ", 1)[1].strip()
        elif line.startswith("state: "):
            values["state"] = line.split(": ", 1)[1].strip()
        elif line.startswith("context.") and ": " in line:
            key, raw_value = line.split(": ", 1)
            try:
                values[key] = json.loads(raw_value)
            except json.JSONDecodeError:
                values[key] = raw_value.strip()
        else:
            match = re.match(r"node (PROBE|CUTOVER|VERIFY)#\d+ succeeded:", line)
            if match:
                nodes.add(match.group(1))
    return values, nodes


if step == "RECOVER_LIVE":
    if ctx.get("recovery_mode") != "verified-live":
        recovery_fail("recovery_mode must be verified-live")

    child = required_recovery_text("recovery_child_execution")
    candidate = required_recovery_text("recovery_candidate")
    candidate_cli = required_recovery_text("recovery_candidate_cli")
    oid = required_recovery_text("recovery_source_git_oid")
    version = required_recovery_text("recovery_version")
    lastdbd_version = required_recovery_text("recovery_lastdbd_version")
    lastdb_version = required_recovery_text("recovery_lastdb_version")
    lastdbd_sha256 = required_recovery_text("recovery_lastdbd_sha256")
    lastdb_sha256 = required_recovery_text("recovery_lastdb_sha256")
    artifact_digest = required_recovery_text("recovery_candidate_artifact_digest")
    protocol_version = required_recovery_text(
        "recovery_safe_upgrade_protocol_version"
    )

    if not re.fullmatch(r"lx-[A-Za-z0-9._-]+", child):
        recovery_fail("recovery_child_execution has an invalid form")
    if protocol_version != "6":
        recovery_fail("recovery child does not use safe-upgrade protocol v6")
    if not re.fullmatch(r"[0-9a-f]{40}", oid):
        recovery_fail("recovery_source_git_oid must be a full lowercase SHA")
    if not re.fullmatch(r"[0-9a-f]{64}", lastdbd_sha256):
        recovery_fail("recovery_lastdbd_sha256 must be one full lowercase SHA-256")
    if not re.fullmatch(r"[0-9a-f]{64}", lastdb_sha256):
        recovery_fail("recovery_lastdb_sha256 must be one full lowercase SHA-256")
    if not re.fullmatch(r"[0-9a-f]{64}", artifact_digest):
        recovery_fail("recovery artifact digest must be one full lowercase SHA-256")
    suffix = re.search(r"-g([0-9a-f]{7,40})$", version)
    if not suffix or not oid.startswith(suffix.group(1)):
        recovery_fail("recovery_version does not identify recovery_source_git_oid")
    if version != lastdbd_version or version != lastdb_version:
        recovery_fail("recovery pair versions do not match the version alias")
    for path, label in (
        (candidate, "recovery_candidate"),
        (candidate_cli, "recovery_candidate_cli"),
    ):
        if not os.path.isabs(path) or not os.path.isfile(path):
            recovery_fail(f"{label} must be an existing absolute file")
        if not os.access(path, os.X_OK):
            recovery_fail(f"{label} is not executable")
        if os.path.realpath(path) != path:
            recovery_fail(f"{label} is not canonical")

    stage_dir = os.path.dirname(candidate)
    manifest_path = os.path.join(stage_dir, "manifest.json")
    if os.path.dirname(candidate_cli) != stage_dir or os.path.basename(candidate_cli) != "lastdb":
        recovery_fail("recovery candidate CLI is not the daemon sibling")
    try:
        with open(manifest_path, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        recovery_fail(f"candidate manifest is unreadable: {error}")
    if manifest.get("source_git_oid") != oid:
        recovery_fail("candidate manifest source does not match")
    if (
        manifest.get("lastdbd_version") != lastdbd_version
        or manifest.get("lastdb_version") != lastdb_version
    ):
        recovery_fail("candidate manifest version does not match")
    if binary_version(candidate, "candidate lastdbd") != lastdbd_version:
        recovery_fail("candidate lastdbd version does not match")
    if binary_version(candidate_cli, "candidate lastdb") != lastdb_version:
        recovery_fail("candidate lastdb version does not match")
    if sha256_file(candidate) != lastdbd_sha256:
        recovery_fail("candidate lastdbd bytes do not match the child receipt")
    if sha256_file(candidate_cli) != lastdb_sha256:
        recovery_fail("candidate lastdb bytes do not match the child receipt")
    actual_digest = hashlib.sha256(
        "\0".join(
            [
                oid,
                candidate,
                candidate_cli,
                lastdbd_sha256,
                lastdb_sha256,
                lastdbd_version,
                lastdb_version,
            ]
        ).encode()
    ).hexdigest()
    if actual_digest != artifact_digest:
        recovery_fail("candidate artifact digest does not match the complete tuple")

    show = run(["loom", "show", child], timeout=30)
    if show.returncode != 0:
        recovery_fail(f"cannot read recovery child rc={show.returncode}")
    receipt, nodes = parse_loom_show(show.stdout)
    expected_receipt = {
        "status": "succeeded",
        "state": "DONE",
        "context.candidate": candidate,
        "context.candidate_cli": candidate_cli,
        "context.source_git_oid": oid,
        "context.version": version,
        "context.lastdbd_version": lastdbd_version,
        "context.lastdb_version": lastdb_version,
        "context.lastdbd_sha256": lastdbd_sha256,
        "context.lastdb_sha256": lastdb_sha256,
        "context.candidate_artifact_digest": artifact_digest,
        "context.safe_upgrade_protocol_version": protocol_version,
        "context.verdict": "green",
        "context.cutover": "live",
        "context.verify": "live",
    }
    for name, expected in expected_receipt.items():
        if receipt.get(name) != expected:
            recovery_fail(f"child receipt {name} does not match")
    if nodes != {"PROBE", "CUTOVER", "VERIFY"}:
        recovery_fail("child receipt lacks successful PROBE, CUTOVER, or VERIFY")

    current_dir = os.environ.get("LAST_STACK_CANARY_RECOVERY_CURRENT_DIR") or os.path.join(
        os.path.expanduser("~"), ".lastdb", "current"
    )
    current_daemon = os.path.join(current_dir, "lastdbd")
    current_cli = os.path.join(current_dir, "lastdb")
    if not os.path.isfile(current_daemon) or not os.path.isfile(current_cli):
        recovery_fail("the canonical current LastDB binary pair is missing")
    if binary_version(current_daemon, "current lastdbd") != lastdbd_version:
        recovery_fail("current lastdbd version does not match")
    if binary_version(current_cli, "current lastdb") != lastdb_version:
        recovery_fail("current lastdb version does not match")
    if sha256_file(current_daemon) != lastdbd_sha256:
        recovery_fail("current lastdbd bytes do not match the child receipt")
    if sha256_file(current_cli) != lastdb_sha256:
        recovery_fail("current lastdb bytes do not match the child receipt")

    status = run([current_cli, "status", "--json", "--timeout", "60"], timeout=90)
    if status.returncode != 0:
        recovery_fail(f"live status failed rc={status.returncode}")
    try:
        live_status = json.loads(status.stdout)
    except json.JSONDecodeError:
        recovery_fail("live status returned invalid JSON")
    if live_status.get("running") is not True or live_status.get("daemon_status") != "running":
        recovery_fail("live daemon is not running")
    if live_status.get("build_agreement") != "agree":
        recovery_fail("live CLI and daemon builds disagree")
    if live_status.get("cli_build") != version or live_status.get("daemon_build") != version:
        recovery_fail("live status version does not match")

    emit(
        {
            "candidate": candidate,
            "candidate_cli": candidate_cli,
            "source_git_oid": oid,
            "version": version,
            "lastdbd_version": lastdbd_version,
            "lastdb_version": lastdb_version,
            "lastdbd_sha256": lastdbd_sha256,
            "lastdb_sha256": lastdb_sha256,
            "candidate_artifact_digest": artifact_digest,
            "safe_upgrade_protocol_version": protocol_version,
            "child_status": "green",
            "recovery_verified": True,
            "recovery_no_mutation": True,
            "recovery_child_execution": child,
            "last_note": "verified already-live candidate; no build or cutover",
        },
        "canary-step RECOVER_LIVE verified",
    )
    raise SystemExit(0)


if step == "READ_A":
    emit({"child_status": "green"}, "canary-step READ_A live assume join-all")
    raise SystemExit(0)


if step == "LEDGER" and ctx.get("recovery_mode") == "verified-live":
    if ctx.get("recovery_verified") is not True or ctx.get("recovery_no_mutation") is not True:
        recovery_fail("verified-live ledger needs the RECOVER_LIVE receipt")

    child = required_recovery_text("recovery_child_execution")
    oid = required_recovery_text("recovery_source_git_oid")
    version = required_recovery_text("recovery_version")
    recovery_bindings = (
        ("candidate", "recovery_candidate"),
        ("candidate_cli", "recovery_candidate_cli"),
        ("source_git_oid", "recovery_source_git_oid"),
        ("version", "recovery_version"),
        ("lastdbd_version", "recovery_lastdbd_version"),
        ("lastdb_version", "recovery_lastdb_version"),
        ("lastdbd_sha256", "recovery_lastdbd_sha256"),
        ("lastdb_sha256", "recovery_lastdb_sha256"),
        ("candidate_artifact_digest", "recovery_candidate_artifact_digest"),
        (
            "safe_upgrade_protocol_version",
            "recovery_safe_upgrade_protocol_version",
        ),
    )
    for verified_name, recovery_name in recovery_bindings:
        if ctx.get(verified_name) != required_recovery_text(recovery_name):
            recovery_fail(
                "verified-live ledger tuple differs from the RECOVER_LIVE receipt"
            )

    # Keep the failed soak terminal. Create one new attempt whose key is stable
    # for this verified child. A retry of this same step is then idempotent.
    ledger_sha = f"{version}-recovery-{child}"
    p = run(
        [
            "last-stack-canary-pipeline",
            "--json",
            "dogfood",
            "--sha",
            ledger_sha,
            "--observed-sha",
            version,
            "--version",
            version,
            "--source",
            "verified-live-recovery",
            "--source-git-oid",
            oid,
        ],
        timeout=120,
    )
    if p.stdout:
        print(p.stdout, end="" if p.stdout.endswith("\n") else "\n")
    if p.stderr:
        sys.stderr.write(p.stderr)
    if p.returncode != 0:
        print(
            f"canary-step LEDGER recovery record failed rc={p.returncode}",
            file=sys.stderr,
        )
        raise SystemExit(p.returncode)
    emit(
        {
            "phase_next": "SOAK",
            "ledger_sha": ledger_sha,
            "source_git_oid": oid,
            "version": version,
            "last_note": f"verified-live recovery ledger recorded sha={ledger_sha}",
        },
        "canary-step LEDGER verified-live recovery",
    )
    raise SystemExit(0)


if step in ("BUILD_START", "BUILD_POLL", "BUILD_COLLECT", "LEDGER", "SOAK", "PROMOTE"):
    env = os.environ.copy()
    env["SM_CONTEXT_JSON"] = json.dumps(ctx)
    env["SM_EXEC_ID"] = os.environ.get("LOOM_EXEC_ID") or "loom-unknown"
    sm_step = {
        "SOAK": "SOAK",
        "PROMOTE": "PROMOTE",
        "BUILD_START": "BUILD_START",
        "BUILD_POLL": "BUILD_POLL",
        "BUILD_COLLECT": "BUILD_COLLECT",
        "LEDGER": "LEDGER",
    }[step]
    p = subprocess.run(
        ["sm-canary-release-step", sm_step],
        capture_output=True,
        text=True,
        timeout=900 if step == "SOAK" else 3600 if step == "PROMOTE" else 300,
        env=env,
    )
    merged = translate_sm(p.stdout)
    if p.stderr:
        sys.stderr.write(p.stderr)
    if p.returncode != 0:
        sys.exit(p.returncode)
    patch = dict(merged)
    if step == "BUILD_POLL":
        patch["build_poll_revision"] = next_revision("build_poll_revision")
    elif step == "SOAK":
        patch["soak_poll_revision"] = next_revision("soak_poll_revision")
    if step == "BUILD_COLLECT":
        job = exact_upgrade_job(
            str(merged.get("candidate") or ctx.get("candidate") or ""),
            str(merged.get("source_git_oid") or ctx.get("source_git_oid") or ""),
            str(merged.get("version") or ctx.get("version") or ""),
        )
        patch.update(job)
        patch["upgrade_jobs"] = [job]
    if patch:
        print(
            "LOOM_CONTEXT_PATCH:"
            + json.dumps(patch, separators=(",", ":"))
        )
    print("PASS")
    raise SystemExit(0)

if step == "RETRY_PREP":
    nxt = attempt + 1
    heal_status = str(ctx.get("heal_status") or "")
    if heal_status in ("blocked", "noop"):
        verdict = "blocked" if heal_status == "blocked" else "idle"
    elif nxt >= max_attempts:
        verdict = "exhausted"
    else:
        verdict = "red"
    emit(
        {"attempt": nxt, "verdict": verdict, "build_next": "BUILD_COLLECT"},
        f"canary-step RETRY_PREP attempt={nxt} verdict={verdict}",
    )
    raise SystemExit(0)

print(f"canary-step: unknown live step {step}", file=sys.stderr)
sys.exit(2)
PY
