#!/usr/bin/env python3
"""Pure sanitizers for structured kanban fields.

Markdown code spans leak wrapping backticks and trailing punctuation into
`pr_url` and `north_star`. Closeout lookup already strips those for LastGit
view, but a dirty stored field still breaks restamp and pipeline oid resolve.

Keep this file free of I/O besides the CLI / --self-test so table tests drive
the same functions the helpers import.
"""
from __future__ import annotations

import re
import sys

_LEADING = re.compile(r"^[`<]+")
_TRAILING = re.compile(r"[`)\]}>.,;]+$")


def sanitize_markdown_wrapped_field(raw: str) -> str:
    value = str(raw or "").strip()
    if not value:
        return ""
    value = _LEADING.sub("", value)
    while _TRAILING.search(value):
        value = _TRAILING.sub("", value)
    return value.strip()


def sanitize_pr_url(raw: str) -> str:
    return sanitize_markdown_wrapped_field(raw)


def sanitize_north_star(raw: str) -> str:
    return sanitize_markdown_wrapped_field(raw)


def pr_url_needs_heal(raw_field: str, normalized: str) -> bool:
    """True when a nonempty normalized URL differs from the stored field.

    Empty stored field + URL from body, or dirty-nonempty stored field, both
    need a structured heal. Already-clean stored field does not.
    """
    stored = str(raw_field or "").strip()
    clean = str(normalized or "").strip()
    return bool(clean) and stored != clean


_PR_URL_CASES = (
    ("", ""),
    ("lastgit://last-stack/cr/cr-mskqwa3y-78c9", "lastgit://last-stack/cr/cr-mskqwa3y-78c9"),
    ("lastgit://last-stack/cr/cr-mskqwa3y-78c9`", "lastgit://last-stack/cr/cr-mskqwa3y-78c9"),
    ("`lastgit://last-stack/cr/cr-mskqwa3y-78c9`", "lastgit://last-stack/cr/cr-mskqwa3y-78c9"),
    ("lastgit://brain/cr/cr-ms8mz1xt-981a`.", "lastgit://brain/cr/cr-ms8mz1xt-981a"),
    ("https://example.test/pull/1)", "https://example.test/pull/1"),
)

_NORTH_STAR_CASES = (
    ("", ""),
    ("north-star-org-cloud-principal-membership", "north-star-org-cloud-principal-membership"),
    ("`north-star-org-cloud-principal-membership`", "north-star-org-cloud-principal-membership"),
)

_HEAL_CASES = (
    ("", "lastgit://last-stack/cr/cr-x", True),
    ("lastgit://last-stack/cr/cr-x`", "lastgit://last-stack/cr/cr-x", True),
    ("lastgit://last-stack/cr/cr-x", "lastgit://last-stack/cr/cr-x", False),
    ("", "", False),
)


def self_test() -> int:
    failed: list[str] = []
    for raw, want in _PR_URL_CASES:
        got = sanitize_pr_url(raw)
        if got != want:
            failed.append(f"pr_url {raw!r}: got {got!r} want {want!r}")
    for raw, want in _NORTH_STAR_CASES:
        got = sanitize_north_star(raw)
        if got != want:
            failed.append(f"north_star {raw!r}: got {got!r} want {want!r}")
    for stored, normalized, want in _HEAL_CASES:
        got = pr_url_needs_heal(stored, normalized)
        if got != want:
            failed.append(
                f"heal stored={stored!r} norm={normalized!r}: got {got!r} want {want!r}"
            )
    if failed:
        for line in failed:
            print(f"FAIL: {line}", file=sys.stderr)
        return 1
    print(f"ok sanitize_structured_fields n={len(_PR_URL_CASES)+len(_NORTH_STAR_CASES)+len(_HEAL_CASES)}")
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: sanitize_structured_fields.py --self-test | pr-url VALUE | north-star VALUE", file=sys.stderr)
        return 2
    if argv[0] == "--self-test":
        return self_test()
    if len(argv) < 2:
        print("usage: sanitize_structured_fields.py pr-url|north-star VALUE", file=sys.stderr)
        return 2
    kind, value = argv[0], argv[1]
    if kind == "pr-url":
        print(sanitize_pr_url(value), end="")
        return 0
    if kind == "north-star":
        print(sanitize_north_star(value), end="")
        return 0
    print(f"unknown kind: {kind}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
