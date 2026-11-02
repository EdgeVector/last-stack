#!/usr/bin/env python3
"""Require exact-source CI qualification instead of local latency benchmarks."""

import argparse
import json
import re
import subprocess


def github(path):
    result = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise ValueError("GitHub CI evidence is unavailable; the primary is unchanged")
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--candidate", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source):
        raise ValueError("CI qualification requires the full source commit")
    version = subprocess.run([args.candidate, "--version"], capture_output=True, text=True, timeout=15)
    if version.returncode or args.source[:9] not in version.stdout:
        raise ValueError("Candidate version does not identify the qualified source")
    base = "repos/EdgeVector/lastdb"
    comparison = github(f"{base}/compare/{args.source}...main?per_page=1")
    if comparison.get("status") not in ("ahead", "identical"):
        raise ValueError("Candidate source is not accepted main history")
    checks = []
    for page in range(1, 11):
        rows = github(f"{base}/commits/{args.source}/check-runs?per_page=100&page={page}")["check_runs"]
        checks.extend(rows)
        if len(rows) < 100:
            break
    else:
        raise ValueError("Candidate CI check history exceeds its page bound")
    accepted = {}
    for name in ("ci-required", "benchmark-complete"):
        matches = [row for row in checks if row.get("name") == name]
        latest = max(matches, key=lambda row: row["id"]) if matches else {}
        if latest.get("status") != "completed" or latest.get("conclusion") != "success":
            raise ValueError(f"Exact-source {name} has not passed; the primary is unchanged")
        accepted[name] = latest["html_url"]
    print(json.dumps({"source": args.source, "performance_gate": "ci", "checks": accepted}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error)) from error
