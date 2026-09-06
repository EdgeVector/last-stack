#!/usr/bin/env python3
"""Print a bounded, secret-safe tail from one DEV photograph proof log."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path


SENSITIVE_NAME = (
    r"(?:api[_-]?key|authorization|token|secret|password|credential|invite(?:[_-]?code)?|"
    r"device[_-]?id|user[_-]?hash|cloud[_-]?db[_-]?hash|manifest[_-]?(?:sha256|key)|"
    r"latest[_-]?key|store[_-]?uuid|identity(?:[_-]?(?:key|seed))?|sha256|digest)"
)
QUOTED_SECRET = re.compile(
    rf"(?i)(?P<prefix>[\"']?{SENSITIVE_NAME}[\"']?\s*[:=]\s*)"
    r"(?P<quote>[\"'])(?P<value>.*?)(?P=quote)"
)
PLAIN_SECRET = re.compile(
    rf"(?i)(?P<prefix>\b{SENSITIVE_NAME}\b\s*[:=]\s*)"
    r"(?P<value>[^\s,;}\]]+)"
)
BEARER = re.compile(r"(?i)\b(Bearer|Basic)\s+\S+")
URL = re.compile(r"https?://[^\s\"']+")
HEX_OR_UUID = re.compile(
    r"(?i)(?<![0-9a-f])(?:[0-9a-f]{16,}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})(?![0-9a-f])"
)
LONG_TOKEN = re.compile(r"(?<![A-Za-z0-9])[A-Za-z0-9_+/=-]{40,}(?![A-Za-z0-9])")
SECRET_ENV_NAME = re.compile(
    r"(?i)(?:api[_-]?key|token|secret|password|passwd|credential|private[_-]?key|"
    r"access[_-]?key|session[_-]?key|invite|device[_-]?id|user[_-]?hash|identity)"
)
SNAPSHOT_ENVELOPE_KEYS = frozenset({"report", "user_hash", "manifest_cache"})


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--cow-home", default="")
    parser.add_argument("--lines", type=int, default=40)
    parser.add_argument("--bytes", type=int, default=32768)
    args = parser.parse_args(argv)
    if not 1 <= args.lines <= 200:
        parser.error("--lines must be from 1 through 200")
    if not 1024 <= args.bytes <= 131072:
        parser.error("--bytes must be from 1024 through 131072")
    return args


def tail_lines(path: Path, byte_limit: int, line_limit: int) -> tuple[list[str], bool]:
    if not path.is_file() or path.is_symlink():
        return [], False
    size = path.stat().st_size
    start = max(0, size - byte_limit)
    with path.open("rb") as handle:
        handle.seek(start)
        raw = handle.read(byte_limit)
    text = raw.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if start and lines:
        lines = lines[1:]
    line_truncated = len(lines) > line_limit
    return lines[-line_limit:], bool(start or line_truncated)


def add_scalar_values(value: object, found: set[str]) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if SECRET_ENV_NAME.search(str(key)) and isinstance(item, (str, int)):
                text = str(item)
                if len(text) >= 4:
                    found.add(text)
            add_scalar_values(item, found)
    elif isinstance(value, list):
        for item in value:
            add_scalar_values(item, found)


def known_secret_values(cow_home: str) -> list[str]:
    values: set[str] = set()
    for name, value in os.environ.items():
        if SECRET_ENV_NAME.search(name) and len(value) >= 6:
            values.add(value)
    if cow_home:
        home = Path(cow_home)
        config = home / "cloud_sync.json"
        try:
            add_scalar_values(json.loads(config.read_text(encoding="utf-8")), values)
        except (OSError, UnicodeError, json.JSONDecodeError):
            pass
        device = home / "data" / ".device_id"
        try:
            value = device.read_text(encoding="utf-8").strip()
            if value:
                values.add(value)
        except (OSError, UnicodeError):
            pass
    return sorted(values, key=len, reverse=True)


def is_snapshot_envelope(line: str) -> bool:
    stripped = line.strip()
    if not (stripped.startswith("{") and stripped.endswith("}")):
        return False
    try:
        value = json.loads(stripped)
    except json.JSONDecodeError:
        return False
    return isinstance(value, dict) and bool(SNAPSHOT_ENVELOPE_KEYS.intersection(value))


def sanitize_line(line: str, cow_home: str, secrets: list[str]) -> str:
    line = "".join(char if char == "\t" or ord(char) >= 32 else "?" for char in line)
    if is_snapshot_envelope(line):
        return "<redacted-snapshot-envelope>"
    if cow_home:
        line = line.replace(cow_home, "<cow>")
    for value in secrets:
        line = line.replace(value, "<redacted-secret>")
    line = BEARER.sub(lambda match: f"{match.group(1)} <redacted-secret>", line)
    line = QUOTED_SECRET.sub(
        lambda match: f"{match.group('prefix')}{match.group('quote')}<redacted-secret>{match.group('quote')}",
        line,
    )
    line = PLAIN_SECRET.sub(lambda match: f"{match.group('prefix')}<redacted-secret>", line)
    line = URL.sub("<redacted-url>", line)
    line = HEX_OR_UUID.sub("<redacted-digest>", line)
    line = LONG_TOKEN.sub("<redacted-token>", line)
    if len(line) > 2000:
        line = line[:2000] + "<line-truncated>"
    return line


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    lines, truncated = tail_lines(Path(args.source), args.bytes, args.lines)
    secrets = known_secret_values(args.cow_home)
    if truncated:
        print("<sanitized-tail-truncated>")
    if not lines:
        print("<no-log-output>")
        return 0
    for line in lines:
        print(sanitize_line(line, args.cow_home, secrets))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except BrokenPipeError:
        raise SystemExit(0)
