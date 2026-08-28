#!/usr/bin/env python3
"""Create a content-timestamp-bounded JSONL corpus for Session Miner."""

import argparse
import datetime as dt
import json
import pathlib
import re
import sys


TIMESTAMP_KEYS = ("timestamp", "time", "created_at", "createdAt")
SESSION_KEYS = ("session_id", "sessionId", "conversation_id", "conversationId")


def parse_timestamp(value):
    if isinstance(value, (int, float)):
        try:
            return dt.datetime.fromtimestamp(value, tz=dt.timezone.utc)
        except (OSError, OverflowError, ValueError):
            return None
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def record_timestamp(record):
    if not isinstance(record, dict):
        return None
    for container in (record, record.get("payload"), record.get("message")):
        if not isinstance(container, dict):
            continue
        for key in TIMESTAMP_KEYS:
            parsed = parse_timestamp(container.get(key))
            if parsed:
                return parsed
    return None


def record_session_id(record):
    if not isinstance(record, dict):
        return ""
    for container in (record, record.get("payload"), record.get("message")):
        if not isinstance(container, dict):
            continue
        for key in SESSION_KEYS:
            value = container.get(key)
            if isinstance(value, str) and value:
                return value
    return ""


def reverse_lines(path, chunk_size=1024 * 1024):
    with path.open("rb") as handle:
        handle.seek(0, 2)
        position = handle.tell()
        remainder = b""
        while position > 0:
            size = min(chunk_size, position)
            position -= size
            handle.seek(position)
            block = handle.read(size) + remainder
            parts = block.split(b"\n")
            remainder = parts[0]
            for raw_line in reversed(parts[1:]):
                if raw_line:
                    yield raw_line.decode("utf-8", errors="replace")
        if remainder:
            yield remainder.decode("utf-8", errors="replace")


def root_arg(value):
    if "=" not in value:
        raise argparse.ArgumentTypeError("root must use LABEL=PATH")
    label, raw_path = value.split("=", 1)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", label):
        raise argparse.ArgumentTypeError("root label contains invalid characters")
    path = pathlib.Path(raw_path).expanduser()
    return label, path


def iso_z(value):
    return value.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def arguments():
    parser = argparse.ArgumentParser()
    window = parser.add_mutually_exclusive_group()
    window.add_argument("--hours", type=float, default=24.0)
    window.add_argument("--since")
    parser.add_argument("--root", action="append", type=root_arg, required=True)
    parser.add_argument("--records-output", type=pathlib.Path)
    return parser.parse_args()


def main():
    args = arguments()
    if args.since:
        cutoff = parse_timestamp(args.since)
        if not cutoff:
            print("invalid --since timestamp", file=sys.stderr)
            return 2
    else:
        if args.hours <= 0:
            print("--hours must be greater than zero", file=sys.stderr)
            return 2
        cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=args.hours)

    output_handle = None
    output_path = None
    if args.records_output:
        output_path = args.records_output.expanduser()
        if not output_path.parent.is_dir():
            print(f"records output directory does not exist: {output_path.parent}", file=sys.stderr)
            return 2
        output_handle = output_path.open("w", encoding="utf-8")

    summary = {
        "cutoff": iso_z(cutoff),
        "roots": [],
        "files_scanned": 0,
        "files_in_window": 0,
        "records_in_window": 0,
        "sessions_in_window": 0,
        "parse_errors": 0,
        "records_without_timestamp": 0,
        "unwindowed_files": [],
    }
    sessions = set()

    try:
        for label, root in args.root:
            if not root.is_dir():
                print(f"transcript root does not exist: {root}", file=sys.stderr)
                return 2
            summary["roots"].append({"harness": label, "path": str(root)})
            for path in root.rglob("*.jsonl"):
                if output_path and path.resolve() == output_path.resolve():
                    continue
                summary["files_scanned"] += 1
                file_has_timestamp = False
                file_has_recent_record = False
                file_sessions = set()
                for line in reverse_lines(path):
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        summary["parse_errors"] += 1
                        continue
                    timestamp = record_timestamp(record)
                    if not timestamp:
                        summary["records_without_timestamp"] += 1
                        continue
                    file_has_timestamp = True
                    if timestamp < cutoff:
                        break
                    if not file_has_recent_record:
                        summary["files_in_window"] += 1
                        file_has_recent_record = True
                    summary["records_in_window"] += 1
                    session_id = record_session_id(record)
                    if session_id:
                        file_sessions.add(session_id)
                    if output_handle:
                        envelope = {
                            "harness": label,
                            "path": str(path),
                            "timestamp": iso_z(timestamp),
                            "record": record,
                        }
                        output_handle.write(json.dumps(envelope, ensure_ascii=False, separators=(",", ":")) + "\n")
                if not file_has_timestamp:
                    summary["unwindowed_files"].append(str(path))
                elif file_has_recent_record:
                    if file_sessions:
                        sessions.update((label, session_id) for session_id in file_sessions)
                    else:
                        sessions.add((label, str(path)))
    finally:
        if output_handle:
            output_handle.close()

    summary["sessions_in_window"] = len(sessions)
    json.dump(summary, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
