#!/usr/bin/env python3
"""Run the real canary CLI with deterministic probe results for gate fixtures."""
import sys
from test_canary_probe_latency import load_pipeline, measured_probe

pipeline = load_pipeline()
observe = pipeline.observe_command


def fixture_observation(path, args):
    expected = {"status": ("build", 3, 2, 2000), "host_fence": ("host", 1, 10, 10000)}
    actual = (args.subject, args.samples, args.timeout_seconds, args.budget_ms)
    if args.check not in expected or actual != expected[args.check]:
        raise AssertionError(f"unexpected gate probe contract: {args.check} {actual}")
    outcomes = {"true": (0, 1, False), "exit 7": (7, 1, False), "exit 9": (9, 1, False),
                "fixture-slow": (0, 3000, False), "fixture-timeout": (0, 2001, True)}
    if args.probe_command not in outcomes:
        raise AssertionError(f"unconfigured fixture probe: {args.probe_command}")
    exit_code, duration, timeout = outcomes[args.probe_command]
    samples = 1 if exit_code or timeout else args.samples
    with measured_probe(pipeline, [duration] * samples, args.probe_command, exit_code, timeout) as run:
        event = observe(path, args)
        if run.call_count != samples:
            raise AssertionError("gate probe sample count changed")
        for call in run.call_args_list:
            if call.args != (args.probe_command,) or call.kwargs["timeout"] != args.timeout_seconds:
                raise AssertionError("gate probe command or deadline changed")
        return event


pipeline.observe_command = fixture_observation
raise SystemExit(pipeline.main(sys.argv[1:]))
