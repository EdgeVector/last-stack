"""A reused PID does not keep the original cleanly stopped DEV session alive."""
import calendar
import time

from native_upgrade_common import alive, require, run
from native_run_v2_inputs import uint


def ended(identity, stop):
    pid, start = uint(identity.get("pid"), True), uint(identity.get("start_ts"), True)
    ledger, receipt = stop.get("session", {}), stop.get("receipt", {})
    require(all(ledger.get(k) == v for k, v in identity.items()) and ledger.get("exit") == "clean"
            and uint(ledger.get("end_ts"), True) >= start
            and receipt == {"version": 1, **identity, "flush_ok": True}
            and type(receipt.get("version")) is int and receipt.get("flush_ok") is True,
            "The original DEV consumer lacks its exact clean session and flush receipt")
    return original_gone(pid, ledger["end_ts"])


def original_gone(pid, existed_by):
    """The original existed by this recorded time; a later kernel owner differs."""
    pid, existed_by = uint(pid, True), uint(existed_by, True)
    if not alive(pid):
        return True
    # Read only the kernel start time, never another process's arguments.
    result = run(["/bin/ps", "-p", str(pid), "-o", "lstart="], check=False,
                 env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C", "TZ": "UTC"})
    if result.returncode != 0 or not result.stdout.strip():
        return not alive(pid)
    require(len(result.stdout) <= 128, "The DEV process start-time sample exceeds its bound")
    try:
        kernel_start = calendar.timegm(time.strptime(result.stdout.strip(), "%a %b %d %H:%M:%S %Y"))
    except ValueError as error:
        raise RuntimeError("The DEV process start-time sample is invalid") from error
    return kernel_start > existed_by
