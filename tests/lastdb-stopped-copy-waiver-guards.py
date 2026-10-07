#!/usr/bin/env python3
"""Check the waiver claim's owner and device rules on a private fixture."""

import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import tempfile
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "skills/lastdb-safe-upgrade/scripts/claim-stopped-copy-waiver.py"
spec = importlib.util.spec_from_file_location("stopped_copy_waiver", SCRIPT)
assert spec is not None and spec.loader is not None
waiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(waiver)


with tempfile.TemporaryDirectory(prefix=".waiver-guards-", dir=ROOT) as fixture:
    fake_home = Path(fixture) / "owner"
    live_home = Path(fixture) / "primary"
    parent = fake_home / waiver.DURABLE_PARENT
    parent.mkdir(parents=True, mode=0o700)
    parent.chmod(0o700)
    live_home.mkdir()
    copy = parent / "copy"

    with mock.patch.dict(os.environ, {"HOME": str(fake_home)}):
        waiver.validate_copy_path(live_home, copy)

        with mock.patch.object(waiver.os, "getuid", return_value=os.getuid() + 1):
            try:
                waiver.validate_copy_path(live_home, copy)
            except ValueError as error:
                assert "not private" in str(error), error
            else:
                raise AssertionError("FAIL: case durable-waiver-owner")

        original_stat = Path.stat

        def other_device(path: Path, *args, **kwargs):
            result = original_stat(path, *args, **kwargs)
            if path == live_home:
                return SimpleNamespace(
                    st_dev=result.st_dev + 1,
                    st_mode=result.st_mode,
                    st_uid=result.st_uid,
                )
            return result

        with mock.patch.object(Path, "stat", other_device):
            try:
                waiver.validate_copy_path(live_home, copy)
            except ValueError as error:
                assert "another device" in str(error), error
            else:
                raise AssertionError("FAIL: case durable-waiver-device")

print("PASS: waiver parent owner and device rules")
