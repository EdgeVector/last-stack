#!/usr/bin/env bash
# Graph A steps. Default stand-in. LOOM_LIVE=1 calls safe-upgrade-lastdb.sh.
set -euo pipefail
step="${1:?step}"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
export LOOM_LASTDB_FRESHNESS_SCRIPT="${LOOM_LASTDB_FRESHNESS_SCRIPT:-$SCRIPT_DIR/lastdb-candidate-freshness.py}"
export LOOM_SAFE_UPGRADE_GRAPH="${LOOM_SAFE_UPGRADE_GRAPH:-$SCRIPT_DIR/lastdb-safe-upgrade.json}"

exec python3 - "$step" <<'PY'
import hashlib, json, os, re, signal, stat, subprocess, sys, tempfile, time
from pathlib import Path

step = sys.argv[1]
raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

item = ctx.get("item")
if isinstance(item, dict):
    immutable = (
        "candidate",
        "candidate_cli",
        "version",
        "lastdbd_version",
        "lastdb_version",
        "lastdbd_sha256",
        "lastdb_sha256",
        "source_git_oid",
        "candidate_artifact_digest",
        "safe_upgrade_protocol_version",
    )
    conflicts = [
        key for key in immutable
        if key in item and key in ctx and item.get(key) != ctx.get(key)
    ]
    if conflicts:
        print(
            "safe-upgrade immutable item/context mismatch: " + ",".join(conflicts),
            file=sys.stderr,
        )
        raise SystemExit(2)
    ctx = {**item, **{k: v for k, v in ctx.items() if k != "item"}}

live = os.environ.get("LOOM_CANARY_LIVE") == "1" or os.environ.get("LOOM_LIVE") == "1"
cand = str(ctx.get("candidate") or "")
cand_cli = str(ctx.get("candidate_cli") or "")
version = str(ctx.get("version") or "")
lastdbd_version = str(ctx.get("lastdbd_version") or "")
lastdb_version = str(ctx.get("lastdb_version") or "")
lastdbd_sha256 = str(ctx.get("lastdbd_sha256") or "")
lastdb_sha256 = str(ctx.get("lastdb_sha256") or "")
source_git_oid = str(ctx.get("source_git_oid") or "")
candidate_artifact_digest = str(ctx.get("candidate_artifact_digest") or "")
safe_upgrade_protocol_version = str(ctx.get("safe_upgrade_protocol_version") or "")


def emit(payload, line="PASS"):
    print("LOOM_CONTEXT_PATCH:" + json.dumps(payload, separators=(",", ":")))
    print(line)
    print("PASS")


def node_timeout(node):
    graph_path = os.environ.get("LOOM_SAFE_UPGRADE_GRAPH") or ""
    if not graph_path or not os.path.isfile(graph_path):
        raise RuntimeError(f"safe-upgrade graph missing: {graph_path}")
    with open(graph_path, encoding="utf-8") as handle:
        graph = json.load(handle)
    value = graph.get("states", {}).get(node, {}).get("timeout_sec")
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise RuntimeError(f"safe-upgrade graph has invalid {node} timeout: {value}")
    return value


def positive_env_seconds(name, default):
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise RuntimeError(f"{name} must be a positive integer")
    if value <= 0:
        raise RuntimeError(f"{name} must be a positive integer")
    return value


def signal_process_group(proc, sig):
    try:
        os.killpg(proc.pid, sig)
    except ProcessLookupError:
        pass


def process_group_exists(proc):
    try:
        os.killpg(proc.pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def close_process_pipes(proc):
    for stream in (proc.stdout, proc.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass


def terminate_owned_group(proc, cleanup_grace, kill_drain, signal_already_sent=False):
    """Bound TERM/KILL and pipe drain for one isolated process group."""
    term_grace = cleanup_grace - kill_drain
    if term_grace <= 0:
        raise RuntimeError(
            "safe-upgrade cleanup grace must exceed its KILL drain reserve"
        )
    if not signal_already_sent:
        signal_process_group(proc, signal.SIGTERM)

    stdout = ""
    stderr = ""
    term_deadline = time.monotonic() + term_grace
    try:
        stdout, stderr = proc.communicate(timeout=term_grace)
    except subprocess.TimeoutExpired:
        pass

    while process_group_exists(proc) and time.monotonic() < term_deadline:
        time.sleep(0.05)
    if process_group_exists(proc):
        signal_process_group(proc, signal.SIGKILL)

    kill_deadline = time.monotonic() + kill_drain
    try:
        more_stdout, more_stderr = proc.communicate(timeout=kill_drain)
        stdout = more_stdout or stdout
        stderr = more_stderr or stderr
    except subprocess.TimeoutExpired as error:
        # A descendant can escape the group but retain a pipe. Never let that
        # escaped descriptor consume the Loom headroom after group KILL.
        if isinstance(error.stdout, str):
            stdout = error.stdout
        if isinstance(error.stderr, str):
            stderr = error.stderr
        close_process_pipes(proc)
        proc.poll()
    while process_group_exists(proc) and time.monotonic() < kill_deadline:
        time.sleep(0.05)
    return stdout or "", stderr or "", not process_group_exists(proc)


class WrapperSignal(Exception):
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def run_recovery_bounded(argv, env, recovery_budget):
    """Run cutover recovery outside the killed driver group."""
    term_grace = positive_env_seconds(
        "LOOM_SAFE_UPGRADE_RECOVERY_TERM_GRACE_SECS", 5
    )
    kill_drain = positive_env_seconds(
        "LOOM_SAFE_UPGRADE_RECOVERY_KILL_DRAIN_SECS", 5
    )
    work_budget = recovery_budget - term_grace - kill_drain
    if work_budget <= 0:
        raise RuntimeError(
            "safe-upgrade recovery timeout leaves no recovery work budget"
        )

    proc = subprocess.Popen(
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
        start_new_session=True,
    )
    cleanup_attempted = False
    try:
        try:
            stdout, stderr = proc.communicate(timeout=work_budget)
            return proc.returncode, stdout or "", stderr or "", False
        except subprocess.TimeoutExpired:
            cleanup_attempted = True
            stdout, stderr, _ = terminate_owned_group(
                proc, term_grace + kill_drain, kill_drain
            )
            return 126, stdout, stderr, True
    finally:
        if cleanup_attempted:
            if process_group_exists(proc):
                signal_process_group(proc, signal.SIGKILL)
                close_process_pipes(proc)
        elif process_group_exists(proc):
            terminate_owned_group(proc, term_grace + kill_drain, kill_drain)


def make_cutover_recovery_state(env):
    """Create the wrapper-owned protocol state in one narrow private root."""
    root = Path(
        env.get("LASTDB_CUTOVER_RECOVERY_ROOT")
        or "~/.local/state/last-stack/lastdb-safe-upgrade/cutover-recovery"
    ).expanduser()
    if not root.is_absolute():
        raise RuntimeError("cutover recovery root must be absolute")
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    root_stat = root.lstat()
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
        raise RuntimeError("cutover recovery root must be a real directory")
    if root.resolve() != root:
        raise RuntimeError("cutover recovery root must not traverse a symlink")
    if root_stat.st_uid != os.getuid() or stat.S_IMODE(root_stat.st_mode) != 0o700:
        raise RuntimeError("cutover recovery root must be owner UID mode 700")

    exec_id = os.environ.get("LOOM_EXEC_ID") or ""
    safe_exec_id = re.sub(r"[^A-Za-z0-9._-]", "_", exec_id)
    if not exec_id or not safe_exec_id:
        raise RuntimeError("cutover recovery state requires a Loom execution id")
    fd, raw_path = tempfile.mkstemp(
        prefix=f"{safe_exec_id}-", suffix=".json", dir=str(root)
    )
    state_path = Path(raw_path)
    initial = {
        "state_version": 1,
        "loom_execution_id": exec_id,
        "stage": "wrapper-started",
        "effect_started": False,
        "venue": "",
        "primary_home": "",
        "primary_socket": "",
        "sidebin_dir": "",
        "launchd_label": "",
        "launchd_plist": "",
        "backup_lastdbd": "",
        "backup_lastdb": "",
        "backup_lastdbd_sha256": "",
        "backup_lastdb_sha256": "",
    }
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(initial, handle, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        state_path.unlink(missing_ok=True)
        raise
    env["LASTDB_CUTOVER_RECOVERY_ROOT"] = str(root)
    env["LASTDB_CUTOVER_RECOVERY_STATE"] = str(state_path)
    return state_path


def remove_cutover_recovery_state(state_path):
    try:
        state_stat = state_path.lstat()
    except FileNotFoundError:
        return
    if (
        not stat.S_ISREG(state_stat.st_mode)
        or stat.S_ISLNK(state_stat.st_mode)
        or state_stat.st_uid != os.getuid()
    ):
        raise RuntimeError("refusing to remove an unsafe cutover recovery state")
    state_path.unlink()


def run_driver_bounded(argv, node, env, recovery_argv=None):
    """Run one driver tree with cleanup and recovery inside the node deadline."""
    if not hasattr(signal, "pthread_sigmask"):
        raise RuntimeError("safe-upgrade wrapper requires POSIX signal masks")
    node_budget = node_timeout(node)
    cleanup_grace = positive_env_seconds(
        "LOOM_SAFE_UPGRADE_CLEANUP_GRACE_SECS", 45
    )
    kill_drain = positive_env_seconds(
        "LOOM_SAFE_UPGRADE_KILL_DRAIN_SECS", 5
    )
    outer_headroom = positive_env_seconds(
        "LOOM_SAFE_UPGRADE_TIMEOUT_HEADROOM_SECS", 15
    )
    recovery_budget = 0
    if recovery_argv is not None:
        recovery_budget = positive_env_seconds(
            "LOOM_SAFE_UPGRADE_RECOVERY_TIMEOUT_SECS", 180
        )
    driver_budget = (
        node_budget - cleanup_grace - recovery_budget - outer_headroom
    )
    if driver_budget <= 0:
        raise RuntimeError(
            f"safe-upgrade {node} timeout leaves no driver budget after cleanup and recovery"
        )
    if cleanup_grace <= kill_drain:
        raise RuntimeError(
            "safe-upgrade cleanup grace must exceed its KILL drain reserve"
        )

    prior_handlers = {}
    external_signal = 0
    recovery_active = False
    shutdown_started = False
    proc = None
    handled_signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)

    def forward_signal(signum, _frame):
        nonlocal external_signal, shutdown_started
        external_signal = external_signal or signum
        if recovery_active or shutdown_started:
            return
        shutdown_started = True
        if proc is not None:
            signal_process_group(proc, signum)
        raise WrapperSignal(signum)

    for signum in handled_signals:
        prior_handlers[signum] = signal.signal(signum, forward_signal)

    stdout = ""
    stderr = ""
    driver_timed_out = False
    driver_reaped = False
    driver_cleanup_attempted = False
    recovery_rc = None
    recovery_stdout = ""
    recovery_stderr = ""
    recovery_timed_out = False
    try:
        try:
            prior_mask = signal.pthread_sigmask(signal.SIG_BLOCK, handled_signals)
            try:
                proc = subprocess.Popen(
                    argv,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    env=env,
                    start_new_session=True,
                    preexec_fn=lambda: signal.pthread_sigmask(
                        signal.SIG_UNBLOCK, handled_signals
                    ),
                )
                if env.get("LOOM_SAFE_UPGRADE_TEST_SIGNAL_AFTER_POPEN") == "TERM":
                    # Test seam: queue TERM while the child exists but before
                    # the parent restores delivery of wrapper signals.
                    os.kill(os.getpid(), signal.SIGTERM)
                    ready_raw = env.get(
                        "LOOM_SAFE_UPGRADE_TEST_SIGNAL_AFTER_POPEN_READY"
                    )
                    if ready_raw:
                        ready_path = Path(ready_raw)
                        if not ready_path.is_absolute():
                            raise RuntimeError("safe-upgrade test ready path must be absolute")
                        ready_deadline = time.monotonic() + 5
                        while not ready_path.exists() and time.monotonic() < ready_deadline:
                            time.sleep(0.01)
                        if not ready_path.exists():
                            raise RuntimeError("safe-upgrade test driver did not become ready")
            finally:
                # A pending signal now runs only after proc owns the detached
                # process group. The child unblocks these signals before exec.
                signal.pthread_sigmask(signal.SIG_SETMASK, prior_mask)
            try:
                stdout, stderr = proc.communicate(timeout=driver_budget)
                # No later signal can interrupt cleanup or CUTOVER recovery.
                # A signal before this assignment reaches the broad catch.
                shutdown_started = True
            except subprocess.TimeoutExpired:
                driver_timed_out = True
                shutdown_started = True
                driver_cleanup_attempted = True
                stdout, stderr, driver_reaped = terminate_owned_group(
                    proc, cleanup_grace, kill_drain
                )
        except WrapperSignal:
            if proc is not None:
                driver_cleanup_attempted = True
                stdout, stderr, driver_reaped = terminate_owned_group(
                    proc, cleanup_grace, kill_drain, signal_already_sent=True
                )

        driver_failed = proc is not None and proc.returncode not in (None, 0)
        if (
            driver_failed
            and not driver_timed_out
            and not external_signal
            and process_group_exists(proc)
        ):
            # A failed driver can leave a same-group emergency daemon after
            # its shell exits. Stop that tree before independent recovery.
            driver_cleanup_attempted = True
            stdout, stderr, driver_reaped = terminate_owned_group(
                proc, cleanup_grace, kill_drain
            )

        recovery_needed = bool(
            recovery_argv is not None
            and (driver_timed_out or external_signal or driver_failed)
        )
        if recovery_needed:
            recovery_active = True
            try:
                recovery_rc, recovery_stdout, recovery_stderr, recovery_timed_out = (
                    run_recovery_bounded(recovery_argv, env, recovery_budget)
                )
            except (OSError, RuntimeError) as error:
                recovery_rc = 127
                recovery_stderr = f"CUTOVER_TIMEOUT_RECOVERY=red reason={error}\n"
            recovery_active = False

        if recovery_needed:
            if recovery_timed_out:
                result_rc = 126
            elif recovery_rc != 0:
                result_rc = 125
            elif external_signal:
                result_rc = 128 + external_signal
            elif driver_timed_out:
                result_rc = 124
            else:
                result_rc = proc.returncode
        elif external_signal:
            result_rc = 128 + external_signal
        elif driver_timed_out:
            result_rc = 124
        else:
            result_rc = proc.returncode
        result = subprocess.CompletedProcess(argv, result_rc, stdout, stderr)
        return (
            result,
            driver_timed_out,
            driver_budget,
            external_signal,
            recovery_rc,
            recovery_stdout,
            recovery_stderr,
            recovery_timed_out,
        )
    finally:
        recovery_active = True
        if proc is not None:
            if driver_cleanup_attempted:
                if not driver_reaped and process_group_exists(proc):
                    signal_process_group(proc, signal.SIGKILL)
                    close_process_pipes(proc)
            elif process_group_exists(proc):
                terminate_owned_group(proc, cleanup_grace, kill_drain)
        for signum, handler in prior_handlers.items():
            signal.signal(signum, handler)


def binary_version(path):
    try:
        proc = subprocess.run(
            [path, "--version"], capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    fields = (proc.stdout or "").strip().split()
    return fields[-1] if proc.returncode == 0 and fields else ""


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def verify_candidate_binding():
    required = {
        "candidate": cand,
        "candidate_cli": cand_cli,
        "version": version,
        "lastdbd_version": lastdbd_version,
        "lastdb_version": lastdb_version,
        "lastdbd_sha256": lastdbd_sha256,
        "lastdb_sha256": lastdb_sha256,
        "source_git_oid": source_git_oid,
        "candidate_artifact_digest": candidate_artifact_digest,
        "safe_upgrade_protocol_version": safe_upgrade_protocol_version,
    }
    missing = [name for name, value in required.items() if not value]
    if missing:
        return False, "candidate binding is missing: " + ",".join(missing)
    if not re.fullmatch(r"[0-9a-f]{40}", source_git_oid):
        return False, "candidate source Git OID is not one full lowercase commit"
    if safe_upgrade_protocol_version != "6":
        return False, "safe-upgrade protocol version is not 6"
    if not re.fullmatch(r"[0-9a-f]{64}", lastdbd_sha256) or not re.fullmatch(
        r"[0-9a-f]{64}", lastdb_sha256
    ):
        return False, "candidate binding has an invalid SHA-256"
    if not re.fullmatch(r"[0-9a-f]{64}", candidate_artifact_digest):
        return False, "candidate artifact digest is not one SHA-256"
    actual_artifact_digest = hashlib.sha256(
        "\0".join(
            [
                source_git_oid,
                cand,
                cand_cli,
                lastdbd_sha256,
                lastdb_sha256,
                lastdbd_version,
                lastdb_version,
            ]
        ).encode()
    ).hexdigest()
    if actual_artifact_digest != candidate_artifact_digest:
        return False, "candidate artifact digest does not match the immutable tuple"
    try:
        daemon_real = str(Path(cand).expanduser().resolve(strict=True))
        cli_real = str(Path(cand_cli).expanduser().resolve(strict=True))
    except OSError as error:
        return False, f"candidate binding path cannot resolve: {error}"
    if daemon_real != cand or cli_real != cand_cli:
        return False, "candidate binding paths are not canonical"
    if Path(cli_real).parent != Path(daemon_real).parent or Path(cli_real).name != "lastdb":
        return False, "candidate CLI is not the sibling lastdb binary"
    if not os.access(daemon_real, os.X_OK) or not os.access(cli_real, os.X_OK):
        return False, "candidate pair is not executable"
    actual_daemon_version = binary_version(daemon_real)
    actual_cli_version = binary_version(cli_real)
    if (
        not actual_daemon_version
        or actual_daemon_version != version
        or actual_daemon_version != lastdbd_version
        or actual_cli_version != lastdb_version
        or actual_cli_version != actual_daemon_version
    ):
        return False, "candidate pair version changed after Loom kickoff"
    try:
        actual_daemon_sha = file_sha256(daemon_real)
        actual_cli_sha = file_sha256(cli_real)
    except OSError as error:
        return False, f"candidate pair cannot be hashed: {error}"
    if actual_daemon_sha != lastdbd_sha256 or actual_cli_sha != lastdb_sha256:
        return False, "candidate pair bytes changed after Loom kickoff"
    return True, "exact candidate pair matches Loom context"


def exact_driver_env():
    env = os.environ.copy()
    env.update(
        {
            "LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID": source_git_oid,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH": cand,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH": cand_cli,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION": lastdbd_version,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION": lastdb_version,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256": lastdbd_sha256,
            "LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256": lastdb_sha256,
        }
    )
    receipt_root = os.environ.get("LASTDB_DEV_STAMP_ROOT") or os.path.expanduser(
        "~/.local/state/last-stack/lastdb-safe-upgrade/dev-photograph-receipts"
    )
    exec_id = os.environ.get("LOOM_EXEC_ID") or ""
    safe_exec_id = re.sub(r"[^A-Za-z0-9._-]", "_", exec_id)
    env["LASTDB_DEV_STAMP_RECEIPT"] = os.path.join(
        receipt_root,
        f"{safe_exec_id}-{lastdbd_sha256[:16]}-{lastdb_sha256[:16]}.receipt",
    )
    return env


def check_freshness():
    script = os.environ.get("LOOM_LASTDB_FRESHNESS_SCRIPT") or ""
    if not script or not os.path.isfile(script):
        return {
            "ok": False,
            "relation": "unknown",
            "reason": f"freshness helper missing: {script}",
        }
    cmd = [sys.executable, script, "--candidate", cand]
    if version:
        cmd.extend(["--candidate-version", version])
    if source_git_oid:
        cmd.extend(["--candidate-source-oid", source_git_oid])
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    lines = [line for line in (p.stdout or "").splitlines() if line.strip()]
    try:
        result = json.loads(lines[-1]) if lines else {}
    except json.JSONDecodeError:
        result = {}
    if not isinstance(result, dict):
        result = {}
    result.setdefault("ok", False)
    result.setdefault("relation", "unknown")
    result.setdefault(
        "reason",
        (p.stderr or "").strip() or f"freshness helper returned rc={p.returncode}",
    )
    print(
        "safe-upgrade freshness "
        f"relation={result['relation']} reason={result['reason']}"
    )
    return result


if not live:
    if step == "PROBE":
        v = os.environ.get("SAFE_UPGRADE_PROBE_VERDICT") or "green"
        emit({"verdict": v, "candidate": cand}, f"su PROBE stand-in verdict={v}")
    elif step == "CUTOVER":
        print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"stand-in-cutover"}')
        print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"stand-in-cutover"}')
        emit({"cutover": "stand-in", "verdict": "green"}, "su CUTOVER stand-in")
    elif step == "VERIFY":
        emit({"verify": "stand-in"}, "su VERIFY stand-in")
    else:
        sys.stderr.write(f"unknown step {step}\n")
        sys.exit(2)
    raise SystemExit(0)

skill = os.path.expanduser(
    "~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
)


def evidence_tail(text, limit=2000):
    lines = [ln.rstrip() for ln in text.splitlines() if ln.strip()]
    return "\n".join(lines[-30:])[-limit:]


def probe_failure_reason(text, final_verdict, rc):
    # The die() line prints only when lock acquisition terminally failed, so
    # this cannot fire on a run that waited, acquired, and then failed a bar.
    if "owns the host-wide safety lane" in text:
        return (
            "safe-upgrade owner lock busy past the wait budget — "
            "harness contention, not a candidate defect"
        )
    reasons = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("REASON:")]
    if reasons:
        return reasons[-1][:400]
    if final_verdict:
        return f"{final_verdict} (rc={rc})"
    return f"driver exited rc={rc} with no VERDICT line"


def write_evidence_file(stage, text, rc):
    """Persist driver output next to the staged candidate.

    Loom keeps no output for a failed node, so without this file a RED
    cutover leaves zero evidence (heal lx-20260830T195506 started blind).
    Best effort: evidence must never turn a probe verdict into a crash.
    """
    if not cand:
        return
    try:
        path = os.path.join(
            os.path.dirname(cand),
            f"{stage}-fail-{os.environ.get('LOOM_EXEC_ID') or 'loom-unknown'}.log",
        )
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(f"stage={stage} rc={rc}\n")
            handle.write(text)
        print(f"su {stage} evidence: {path}", file=sys.stderr)
    except OSError as err:
        print(f"su {stage} evidence write failed: {err}", file=sys.stderr)

if step == "PROBE":
    if not cand:
        emit({"verdict": "red"}, "su PROBE no candidate")
        raise SystemExit(0)
    bound, binding_reason = verify_candidate_binding()
    if not bound:
        emit(
            {"verdict": "red", "last_error": binding_reason},
            "su PROBE exact candidate binding refused",
        )
        raise SystemExit(0)
    freshness = check_freshness()
    relation = str(freshness.get("relation") or "unknown")
    if freshness.get("ok") and relation == "current":
        emit(
            {"verdict": "current", "freshness": relation},
            "su PROBE candidate already current",
        )
        raise SystemExit(0)
    if not freshness.get("ok") or relation != "forward":
        emit(
            {
                "verdict": "red",
                "freshness": relation,
                "last_error": str(freshness.get("reason") or "ancestry unproved"),
            },
            f"su PROBE freshness={relation} refused",
        )
        raise SystemExit(0)
    # Loom can re-dispatch a long PROBE after its caller reaches the drive
    # deadline. The immutable execution context already contains the exact
    # prior result. Reuse only a clean GREEN result after the current
    # freshness check. CUTOVER runs the complete safe-upgrade driver again,
    # so this skips no live safety gate.
    if (
        ctx.get("verdict") == "green"
        and type(ctx.get("probe_rc")) is int
        and ctx.get("probe_rc") == 0
        and not ctx.get("last_error")
    ):
        # Do not write the same context patch again. The new revision can race
        # the state advance and leave PROBE selected for another dispatch.
        print("su PROBE reused exact stored green result")
        print("PASS")
        raise SystemExit(0)
    # A re-dispatched PROBE can find the owner lock still held by an earlier
    # attempt's orphaned process tree. Wait for the lane instead of marking
    # the candidate RED; the budget stays well under the PROBE node timeout.
    probe_env = exact_driver_env()
    probe_env.setdefault("LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S", "2700")
    (
        p,
        driver_timed_out,
        driver_timeout,
        external_signal,
        _recovery_rc,
        _recovery_stdout,
        _recovery_stderr,
        _recovery_timed_out,
    ) = run_driver_bounded(
        ["bash", skill, "--candidate", cand, "--probe-only"], "PROBE", probe_env,
    )
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    timeout_note = ""
    if driver_timed_out:
        timeout_note = (
            f"safe-upgrade PROBE driver timed out after {driver_timeout}s; "
            "its isolated process group received TERM before KILL"
        )
        sys.stderr.write(timeout_note + "\n")
    text = (p.stdout or "") + (p.stderr or "")
    if timeout_note:
        text += ("" if text.endswith("\n") or not text else "\n") + timeout_note + "\n"
    if external_signal:
        signal_note = (
            f"safe-upgrade PROBE wrapper received signal {external_signal}; "
            "it forwarded the signal and reaped the isolated driver group"
        )
        text += ("" if text.endswith("\n") or not text else "\n") + signal_note + "\n"
        sys.stderr.write(signal_note + "\n")
        write_evidence_file("probe", text, p.returncode)
        raise SystemExit(p.returncode)
    # The driver cats sub-probe output (smoke prints its own "VERDICT: GREEN"),
    # so a substring match false-greens a red probe: rc=1 runs reached CUTOVER
    # on lx-20260830T203912.259-78723-1. Only the driver's FINAL verdict line
    # plus rc==0 is green.
    verdicts = [ln.strip() for ln in text.splitlines() if ln.strip().startswith("VERDICT:")]
    final_verdict = verdicts[-1] if verdicts else ""
    green = p.returncode == 0 and final_verdict in (
        "VERDICT: GREEN",
        "VERDICT: GREEN_PROBE_ONLY",
    )
    patch = {"verdict": "green" if green else "red", "probe_rc": p.returncode}
    if not green:
        patch["last_error"] = timeout_note or probe_failure_reason(
            text, final_verdict, p.returncode
        )
        patch["probe_tail"] = evidence_tail(text)
        write_evidence_file("probe", text, p.returncode)
    emit(patch, f"su PROBE verdict={patch['verdict']}")
    raise SystemExit(0)

if step == "CUTOVER":
    bound, binding_reason = verify_candidate_binding()
    if not bound:
        sys.stderr.write(f"safe-upgrade CUTOVER refused: {binding_reason}\n")
        raise SystemExit(1)
    freshness = check_freshness()
    relation = str(freshness.get("relation") or "unknown")
    if freshness.get("ok") and relation == "current":
        emit(
            {"cutover": "already-current", "verdict": "green", "freshness": relation},
            "su CUTOVER candidate became current; no live change",
        )
        raise SystemExit(0)
    if not freshness.get("ok") or relation != "forward":
        sys.stderr.write(
            "safe-upgrade CUTOVER refused: "
            f"freshness={relation} reason={freshness.get('reason') or 'ancestry unproved'}\n"
        )
        raise SystemExit(1)
    print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"lastdb-safe-upgrade"}')
    cutover_env = exact_driver_env()
    cutover_env["LASTDB_SAFE_UPGRADE_VIA_LOOM"] = "1"
    cutover_env.setdefault("LASTDB_SAFE_UPGRADE_OWNER_LOCK_WAIT_S", "1800")
    state_path = make_cutover_recovery_state(cutover_env)
    recovery_script_raw = os.environ.get(
        "LOOM_SAFE_UPGRADE_CUTOVER_RECOVERY_SCRIPT"
    ) or str(Path(skill).resolve().parent / "cutover-timeout-recovery.sh")
    recovery_script = str(Path(recovery_script_raw).expanduser().resolve(strict=True))
    recovery_argv = [
        "bash",
        recovery_script,
        "--state",
        str(state_path),
        "--loom-exec-id",
        os.environ.get("LOOM_EXEC_ID") or "",
    ]
    preserve_recovery_state = True
    try:
        (
            p,
            driver_timed_out,
            driver_timeout,
            external_signal,
            recovery_rc,
            recovery_stdout,
            recovery_stderr,
            recovery_timed_out,
        ) = run_driver_bounded(
            ["bash", skill, "--candidate", cand, "--yes"],
            "CUTOVER",
            cutover_env,
            recovery_argv,
        )
        preserve_recovery_state = bool(
            recovery_rc is not None
            and (recovery_timed_out or recovery_rc != 0)
        )
    finally:
        if not preserve_recovery_state:
            remove_cutover_recovery_state(state_path)
    sys.stdout.write(p.stdout or "")
    sys.stderr.write(p.stderr or "")
    sys.stdout.write(recovery_stdout or "")
    sys.stderr.write(recovery_stderr or "")
    timeout_note = ""
    if driver_timed_out:
        if recovery_timed_out:
            recovery_result = (
                "bounded supervisor recovery timed out; "
                f"exact state retained at {state_path}"
            )
        elif recovery_rc == 0:
            recovery_result = "bounded supervisor recovery succeeded"
        else:
            recovery_result = (
                f"bounded supervisor recovery failed rc={recovery_rc}; "
                f"exact state retained at {state_path}"
            )
        timeout_note = (
            f"safe-upgrade CUTOVER driver timed out after {driver_timeout}s; "
            "its isolated process group received TERM before KILL; "
            f"{recovery_result}"
        )
        sys.stderr.write(timeout_note + "\n")
    signal_note = ""
    if external_signal:
        if recovery_timed_out:
            recovery_result = (
                "bounded supervisor recovery timed out; "
                f"exact state retained at {state_path}"
            )
        elif recovery_rc == 0:
            recovery_result = "bounded supervisor recovery succeeded"
        else:
            recovery_result = (
                f"bounded supervisor recovery failed rc={recovery_rc}; "
                f"exact state retained at {state_path}"
            )
        signal_note = (
            f"safe-upgrade CUTOVER wrapper received signal {external_signal}; "
            "it forwarded the signal and reaped the isolated driver group; "
            f"{recovery_result}"
        )
        sys.stderr.write(signal_note + "\n")
    failure_note = ""
    if p.returncode != 0 and not driver_timed_out and not external_signal:
        if recovery_timed_out:
            recovery_result = (
                "bounded supervisor recovery timed out; "
                f"exact state retained at {state_path}"
            )
        elif recovery_rc == 0:
            recovery_result = "bounded supervisor recovery succeeded"
        else:
            recovery_result = (
                f"bounded supervisor recovery failed rc={recovery_rc}; "
                f"exact state retained at {state_path}"
            )
        failure_note = (
            "safe-upgrade CUTOVER driver exited nonzero; "
            f"{recovery_result}"
        )
        sys.stderr.write(failure_note + "\n")
    if p.returncode != 0:
        evidence = (
            (p.stdout or "")
            + (p.stderr or "")
            + (recovery_stdout or "")
            + (recovery_stderr or "")
        )
        if timeout_note:
            evidence += ("" if evidence.endswith("\n") or not evidence else "\n")
            evidence += timeout_note + "\n"
        if signal_note:
            evidence += ("" if evidence.endswith("\n") or not evidence else "\n")
            evidence += signal_note + "\n"
        if failure_note:
            evidence += ("" if evidence.endswith("\n") or not evidence else "\n")
            evidence += failure_note + "\n"
        write_evidence_file("cutover", evidence, p.returncode)
        sys.exit(p.returncode)
    print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"lastdb-safe-upgrade"}')
    emit({"cutover": "live", "verdict": "green"}, "su CUTOVER live")
    raise SystemExit(0)

if step == "VERIFY":
    p = subprocess.run(["kanban", "list", "--column", "todo"], capture_output=True, text=True, timeout=120)
    if p.returncode != 0:
        sys.stderr.write(p.stderr or "")
        sys.exit(p.returncode)
    emit({"verify": "live"}, "su VERIFY live")
    raise SystemExit(0)

sys.stderr.write(f"unknown live step {step}\n")
sys.exit(2)
PY
