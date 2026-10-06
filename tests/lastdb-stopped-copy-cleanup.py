#!/usr/bin/env python3
"""Fixture checks for one exact stopped-copy cleanup; no live home is used."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "skills/lastdb-safe-upgrade/scripts/cleanup-stopped-copy.py"
TEMP_ROOT = Path("/private/tmp")


class CleanupTest(unittest.TestCase):
    def setUp(self) -> None:
        if sys.platform != "darwin":
            self.skipTest("the stopped-copy helper runs only on macOS")
        self.copy = Path(tempfile.mkdtemp(prefix="lastdb-stopped-backup-test-", dir=TEMP_ROOT))
        self.restored = Path(tempfile.mkdtemp(prefix="lastdb-rescue-restore-test-", dir=TEMP_ROOT))
        report_fd, report_name = tempfile.mkstemp(prefix="lastdb-rescue-report-", dir=TEMP_ROOT)
        os.close(report_fd)
        self.report = Path(report_name)
        self.addCleanup(self.cleanup_fixture)
        self.sha = "a" * 64
        self.store_uuid = "fixture-store-uuid"
        self.db_hash = hashlib.sha256(f"laststore-db:{self.store_uuid}".encode()).hexdigest()
        self.counter = 618
        (self.copy / "data").mkdir()
        (self.restored / "data").mkdir()
        (self.copy / "identity.key").write_bytes(b"fixture identity")
        for home in (self.copy, self.restored):
            (home / "cloud_sync.json.paused").write_text("fixture only")
            (home / ".cloud_resume_required").write_bytes(b"")
            self.put_json(home / "laststore_high_water.json", {"store_uuid": self.store_uuid})
        (self.restored / ".bootstrap_done").write_bytes(b"ok\n")
        self.put_json(self.copy / ".shutdown_flush_ready", {
            "version": 1, "pid": 4242, "start_ts": 123456, "flush_ok": True,
        })
        self.put_json(self.copy / ".cloud_backup_source_copy", {
            "version": 1, "source_pid": 4242, "source_start_ts": 123456,
            "copied_at_unix_s": 123999,
        })
        common = {
            "version": 1, "db_hash": self.db_hash, "store_uuid": self.store_uuid,
            "manifest_sha256": self.sha, "counter": self.counter, "cloud_sync_off": True,
        }
        self.put_json(self.copy / ".rescue_s0_complete", {
            **common, "descriptor_name": "fixture.enc", "descriptor_sha256": "b" * 64,
            "rescue_key": f"rescue/s0/{self.sha}.json",
        })
        result = {**common, "ok": True, "restore_mode": "s0_only"}
        self.put_json(self.restored / ".rescue_s0_restore_ready", result)
        self.put_json(self.report, {
            **result, "source_scope_verified": True, "remote_read_only": True,
        })

    def cleanup_fixture(self) -> None:
        if self.copy.is_symlink():
            self.copy.unlink()
        elif self.copy.exists():
            shutil.rmtree(self.copy)
        if self.restored.exists():
            shutil.rmtree(self.restored)
        if self.report.exists():
            self.report.unlink()

    @staticmethod
    def put_json(path: Path, value: dict) -> None:
        path.write_text(json.dumps(value))

    def run_helper(self, *extra: str, environment=None) -> subprocess.CompletedProcess[str]:
        return subprocess.run([
            sys.executable, str(HELPER), "--copy", str(self.copy),
            "--restored-home", str(self.restored), "--restore-report", str(self.report),
            "--expect-db-hash", self.db_hash, "--expect-manifest-sha256", self.sha,
            *extra,
        ], text=True, capture_output=True, env=environment)

    def test_check_only_keeps_the_copy(self) -> None:
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STOPPED_COPY_CLEANUP=checked", result.stdout)
        self.assertTrue(self.copy.is_dir())

    def test_report_identity_mismatch_refuses_delete(self) -> None:
        report = json.loads(self.report.read_text())
        report["manifest_sha256"] = "c" * 64
        self.put_json(self.report, report)
        result = self.run_helper("--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.copy.is_dir())

    def test_missing_restored_receipt_refuses_delete(self) -> None:
        (self.restored / ".rescue_s0_restore_ready").unlink()
        result = self.run_helper("--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.copy.is_dir())

    def test_flush_session_mismatch_refuses_delete(self) -> None:
        receipt = json.loads((self.copy / ".shutdown_flush_ready").read_text())
        receipt["start_ts"] += 1
        self.put_json(self.copy / ".shutdown_flush_ready", receipt)
        result = self.run_helper("--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.copy.is_dir())

    def test_restore_report_must_be_remote_read_only(self) -> None:
        report = json.loads(self.report.read_text())
        report["remote_read_only"] = False
        self.put_json(self.report, report)
        result = self.run_helper("--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.copy.is_dir())

    def test_active_cloud_config_refuses_delete(self) -> None:
        (self.restored / "cloud_sync.json").write_bytes(b"fixture only")
        result = self.run_helper("--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.copy.is_dir())

    def test_active_copy_process_refuses_delete(self) -> None:
        process = subprocess.Popen([
            sys.executable, "-c", "import time; time.sleep(30)", str(self.copy),
        ])
        self.addCleanup(process.wait)
        self.addCleanup(process.terminate)
        result = self.run_helper("--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("a process still names a rescue home", result.stderr)
        self.assertTrue(self.copy.is_dir())

    def test_socket_path_refuses_delete(self) -> None:
        (self.copy / "data" / "folddb.sock").write_bytes(b"fixture only")
        result = self.run_helper("--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.copy.is_dir())

    def test_open_file_refuses_delete_without_path_in_command(self) -> None:
        held = self.copy / "data" / "held.bin"
        held.write_bytes(b"fixture only")
        environment = {**os.environ, "TEST_OPEN_FILE": str(held)}
        process = subprocess.Popen([
            sys.executable, "-u", "-c",
            "import os,time; f=open(os.environ['TEST_OPEN_FILE'],'rb'); print('ready',flush=True); time.sleep(30)",
        ], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(process.stdout.close)
        self.addCleanup(process.stderr.close)
        self.addCleanup(process.wait)
        self.addCleanup(process.terminate)
        self.assertEqual(process.stdout.readline(), b"ready\n")
        result = self.run_helper("--execute")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("a process still has a rescue file open", result.stderr)
        self.assertTrue(self.copy.is_dir())

    def test_open_file_check_error_refuses_delete(self) -> None:
        fake_dir = Path(tempfile.mkdtemp(prefix="lastdb-fake-lsof-", dir=TEMP_ROOT))
        self.addCleanup(shutil.rmtree, fake_dir)
        fake_lsof = fake_dir / "lsof"
        fake_lsof.write_text("#!/usr/bin/env python3\nimport sys\nsys.stderr.write('fixture error\\n')\nsys.exit(1)\n")
        fake_lsof.chmod(0o700)
        environment = {**os.environ, "PATH": f"{fake_dir}:{os.environ['PATH']}"}
        result = self.run_helper("--execute", environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.copy.is_dir())

    def test_symlink_copy_refuses_delete(self) -> None:
        real = self.copy
        alias = TEMP_ROOT / f"lastdb-stopped-backup-alias-{os.getpid()}"
        alias.symlink_to(real)
        self.addCleanup(alias.unlink)
        self.copy = alias
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is a symlink or alias", result.stderr)
        self.assertTrue(real.is_dir())
        self.copy = real

    def test_execute_deletes_only_the_stopped_copy(self) -> None:
        result = self.run_helper("--execute")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("STOPPED_COPY_CLEANUP=deleted", result.stdout)
        self.assertFalse(self.copy.exists())
        self.assertTrue((self.restored / ".rescue_s0_restore_ready").is_file())


if __name__ == "__main__":
    unittest.main()
