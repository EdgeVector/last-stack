"""Exercise production probe decisions with controlled command durations."""
import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest.mock import Mock, patch


def load_pipeline():
    source = Path(__file__).resolve().parents[1] / "bin/last-stack-canary-pipeline"
    loader = importlib.machinery.SourceFileLoader("canary_probe_pipeline", str(source))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


@contextlib.contextmanager
def measured_probe(pipeline, durations_ms, command="fixture-probe", exit_code=0, timeout=False):
    # Replace only this module's clock object; subprocess timeout internals keep
    # the real standard-library clock. No live command runs in this fixture.
    ticks = [tick for duration in durations_ms for tick in (0, duration / 1000)]
    clock = types.SimpleNamespace(monotonic=Mock(side_effect=ticks))
    outcome = subprocess.CompletedProcess(command, exit_code)
    effect = subprocess.TimeoutExpired(command, 2) if timeout else None
    with patch.object(pipeline, "time", clock), patch.object(
        pipeline.subprocess, "run", return_value=outcome, side_effect=effect
    ) as run:
        yield run


class ProbeLatencyTests(unittest.TestCase):
    def setUp(self):
        self.pipeline = load_pipeline()

    def test_median_accepts_one_outlier_and_rejects_two(self):
        for durations, expected in (([2000, 1, 1], True), ([2000, 2000, 1], False)):
            with self.subTest(durations=durations), patch.dict(os.environ, {
                "FIXTURE_CHECK_CMD": "fixture-probe",
                "LAST_STACK_CANARY_WRITE_MS_MAX": "1000",
                "LAST_STACK_CANARY_CHECK_SAMPLES": "3",
                "LAST_STACK_CANARY_CHECK_FAIL_RETRIES": "0",
            }), measured_probe(self.pipeline, durations) as run:
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    actual = self.pipeline.run_check("board_write", "FIXTURE_CHECK_CMD", "unused")
                self.assertIs(actual, expected)
                self.assertEqual(run.call_count, 3)
                if not expected:
                    self.assertIn("slow_median_ms=2000", self.pipeline.CHECK_FAILURE_DETAIL["board_write"])

    def observation(self, durations, *, exit_code=0, timeout=False):
        args = argparse.Namespace(candidate="fixture", check="status", subject="build",
            probe_command="fixture-probe", samples=3, timeout_seconds=2, budget_ms=2000, at="")
        with tempfile.TemporaryDirectory() as tmp, measured_probe(
            self.pipeline, durations, exit_code=exit_code, timeout=timeout
        ) as run:
            event = self.pipeline.observe_command(Path(tmp) / "ledger.jsonl", args)
            self.assertEqual(run.call_count, len(durations))
            for call in run.call_args_list:
                self.assertEqual(call.args, ("fixture-probe",))
                self.assertEqual(call.kwargs["timeout"], 2)
            return event

    def test_p95_accepts_fast_samples(self):
        event = self.observation([1, 2, 3])
        self.assertTrue(event["passed"])
        self.assertEqual(event["samples"], 3)
        self.assertEqual(event["p95_ms"], 3)

    def test_p95_rejects_one_slow_sample(self):
        event = self.observation([1, 2, 3000])
        self.assertFalse(event["passed"])
        self.assertEqual(event["p95_ms"], 3000)

    def test_exit_failure_survives(self):
        event = self.observation([1], exit_code=7)
        self.assertFalse(event["passed"])
        self.assertEqual(event["detail"], "exit_7")

    def test_timeout_survives(self):
        event = self.observation([2001], timeout=True)
        self.assertFalse(event["passed"])
        self.assertEqual(event["detail"], "timeout")


if __name__ == "__main__":
    unittest.main()
