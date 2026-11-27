#!/usr/bin/env python3
"""Read one exact safe-upgrade result from Loom's local recovery journal."""

import argparse
import json
from pathlib import Path
import re
import sys

MAX_TAIL_BYTES = 16 * 1024 * 1024
MAX_RECORD_BYTES = 1024 * 1024


def receipt(journal, key, expected):
    encoded_key = key.encode()
    latest = None
    # This run just returned; its final full record belongs in this bounded tail.
    with journal.open("rb") as stream:
        offset = max(0, journal.stat().st_size - MAX_TAIL_BYTES)
        stream.seek(offset)
        if offset:
            stream.readline(MAX_RECORD_BYTES + 1)
        remaining = MAX_TAIL_BYTES
        while remaining > 0:
            line = stream.readline(min(MAX_RECORD_BYTES + 1, remaining))
            if not line:
                break
            remaining -= len(line)
            if len(line) > MAX_RECORD_BYTES or not line.endswith(b"\n"):
                raise ValueError("journal record is incomplete or exceeds its bound")
            if encoded_key not in line:
                continue
            record = json.loads(line)
            fields = record.get("fields", {})
            if record.get("schema") != "LoomExecution" or fields.get("idempotency_key") != key:
                continue
            if fields.get("definition_name") != "lastdb-safe-upgrade" \
                    or fields.get("execution_mode") != "local-recovery" \
                    or json.loads(fields["input_json"]) != expected:
                raise ValueError("execution binding differs")
            execution = fields.get("exec_id", "")
            if not re.fullmatch(r"lx-[A-Za-z0-9.-]+", execution) \
                    or fields.get("id") != execution or record.get("hash") != execution:
                raise ValueError("execution identity differs")
            status, state = fields.get("status"), fields.get("state")
            if status not in {"initializing", "succeeded", "failed", "running", "waiting", "paused"} \
                    or not isinstance(state, str) or not state:
                raise ValueError("execution status is invalid")
            latest = {"execution": execution, "status": status, "state": state}
    if latest is None:
        raise ValueError("exact execution is absent from the bounded journal tail")
    return latest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("journal", type=Path)
    parser.add_argument("key")
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read(MAX_RECORD_BYTES + 1)
        if len(raw) > MAX_RECORD_BYTES:
            raise ValueError("expected input exceeds its bound")
        expected = json.loads(raw)
        if not isinstance(expected, dict) or not re.fullmatch(
                r"[0-9a-f]{40}", expected.get("source_git_oid", "")):
            raise ValueError("expected source is invalid")
        print(json.dumps(receipt(args.journal, args.key, expected), sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError):
        parser.exit(1, "local safe-upgrade receipt unavailable or mismatched\n")


if __name__ == "__main__":
    main()
