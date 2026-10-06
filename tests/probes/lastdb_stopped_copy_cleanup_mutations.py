#!/usr/bin/env python3
"""Remove one stopped-copy cleanup guard for a focused test."""

from pathlib import Path
import sys


MUTATIONS = {
    "check_only": (
        "        if args.execute:\n",
        "        if True:\n",
    ),
    "identity": (
        '        refuse("rescue identities do not match")',
        "        return",
    ),
    "restore_receipt": (
        '    target = read_json(restored / ".rescue_s0_restore_ready")',
        '    target = {**read_json(copy / ".rescue_s0_complete"), "ok": True, "restore_mode": "s0_only"}',
    ),
    "flush_session": (
        '        refuse("stopped copy session does not match the flush")',
        "        pass",
    ),
    "remote_read_only": (
        '    if report.get("source_scope_verified") is not True or report.get("remote_read_only") is not True:',
        "    if False:",
    ),
    "active_config": (
        '    require_absent(home / "cloud_sync.json")',
        "    pass",
    ),
    "active_process": (
        "    require_no_home_process(copy, restored)",
        "    pass",
    ),
    "socket_path": (
        '            require_absent(home / "data" / name)',
        "            pass",
    ),
    "open_file": (
        "    require_no_open_files(copy)",
        "    pass",
    ),
    "open_file_error": (
        "    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():",
        "    if result.returncode == 1 and not result.stdout.strip():",
    ),
    "open_file_rc1": (
        "    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():",
        "    if result.returncode == 1:",
    ),
    "symlink_copy": (
        "    if stat.S_ISLNK(status.st_mode) or path.resolve() != path:",
        "    if False:",
    ),
}


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in MUTATIONS:
        raise SystemExit("usage: script <mutation> <target>")
    path = Path(sys.argv[2])
    data = path.read_text()
    old, new = MUTATIONS[sys.argv[1]]
    assert data.count(old) == 1, f"expected one anchor for {sys.argv[1]}"
    path.write_text(data.replace(old, new, 1))


if __name__ == "__main__":
    main()
