#!/usr/bin/env python3
"""Every bin/ helper a skill or routine runs by bare name has a PATH link.

papercut-host-track-links-no-lint-for-bare-named-helpers-20260923: host-track
`links[]` in config/host-track/apps.json is a literal list. A new helper that a
skill or routine runs by bare name gets no ~/.local/bin link, and the call
fails with exit 127 only at use time.

This test reads fenced code blocks in skills/**/*.md and routines/*.md. A
`last-stack-*` word in COMMAND POSITION (line start, after `|`, `&&`, `||`,
`;`, `$(`, `!`, `if`, `then`, `do`, `exec`, `env ...`, `timeout N`, or leading
VAR=value assignments) whose bin/ file exists must have a last-stack links[]
entry, or be listed in tests/fixtures/host-track-links-bare-exempt.txt with a
reason. Path forms (`$last_stack/bin/x`, `~/.last-stack/bin/x`) are not bare.

It also fails when a PATH-linked shell helper takes `dirname "$0"` without
resolving the file symlink first: through ~/.local/bin that dirname is
~/.local/bin and sibling helpers are missing
(papercut-card-closeout-path-link-self-dir-misses-sibling-helpers-20260923).

It also fails when an exemption names a helper that is now linked or no longer
bare-called, so the exemption list cannot rot.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXEMPT = ROOT / "tests/fixtures/host-track-links-bare-exempt.txt"

PREFIX = (
    r"(?:^|\|\||&&|[|;(!]|\$\(|\bif\b|\bthen\b|\bdo\b|\bexec\b|\btime\b)"
    r"\s*(?:env\s+(?:-u\s+\S+\s+)*)?(?:timeout\s+\S+\s+)?(?:[A-Z_][A-Z0-9_]*=\S*\s+)*"
)
CMD_RE = re.compile(PREFIX + r"(last-stack-[a-z0-9][a-z0-9-]*)(?=\s|$|[;|&)`])")


def fenced_lines(text: str):
    fence = None
    for line in text.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            marker = stripped[:3]
            if fence is None:
                fence = marker
            elif marker == fence:
                fence = None
            continue
        if fence is not None:
            yield line


def bare_calls() -> dict[str, list[str]]:
    docs = sorted((ROOT / "skills").glob("*/SKILL.md"))
    docs += sorted((ROOT / "skills").glob("*/*.md"))
    docs += sorted((ROOT / "skills").glob("*/*/*.md"))
    docs += sorted((ROOT / "routines").glob("*.md"))
    seen: dict[str, list[str]] = {}
    for doc in dict.fromkeys(docs):
        rel = doc.relative_to(ROOT).as_posix()
        for line in fenced_lines(doc.read_text(encoding="utf-8", errors="replace")):
            for m in CMD_RE.finditer(line):
                name = m.group(1)
                start = m.start(1)
                if start > 0 and line[start - 1] in "/.-_$":
                    continue
                if (ROOT / "bin" / name).is_file():
                    seen.setdefault(name, [])
                    if rel not in seen[name]:
                        seen[name].append(rel)
    return seen


def linked() -> set[str]:
    reg = json.loads((ROOT / "config/host-track/apps.json").read_text())
    out: set[str] = set()
    for app in reg.get("apps", []):
        if app.get("app") != "last-stack":
            continue
        for link in app.get("links", []):
            src = str(link.get("source") or "")
            if src.startswith("bin/"):
                out.add(src[len("bin/"):])
    return out


def exemptions() -> dict[str, str]:
    out: dict[str, str] = {}
    if not EXEMPT.is_file():
        return out
    for raw in EXEMPT.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        name, _, reason = line.partition(" ")
        if not reason.strip():
            print(f"FAIL: exemption {name} has no reason", file=sys.stderr)
            sys.exit(1)
        out[name] = reason.strip()
    return out


UNRESOLVED_SELF = re.compile(r'dirname (?:-- )?"\$0"')


def main() -> int:
    calls = bare_calls()
    links = linked()
    exempt = exemptions()
    fail = False
    for name in sorted(links):
        path = ROOT / "bin" / name
        if not path.is_file():
            continue
        head = path.read_text(encoding="utf-8", errors="replace")
        if not head.startswith("#!") or "python" in head.splitlines()[0]:
            continue
        for lineno, line in enumerate(head.splitlines(), 1):
            if UNRESOLVED_SELF.search(line):
                fail = True
                print(
                    f"FAIL: bin/{name}:{lineno} is PATH-linked and takes dirname \"$0\" without "
                    "resolving the symlink; resolve the chain with readlink first.",
                    file=sys.stderr,
                )
    for name in sorted(calls):
        if name in links or name in exempt:
            continue
        fail = True
        print(
            f"FAIL: {name} is run by bare name in {', '.join(calls[name][:3])} but has no "
            f"last-stack links[] entry in config/host-track/apps.json (exit 127 at use).",
            file=sys.stderr,
        )
    for name in sorted(exempt):
        if name in links:
            fail = True
            print(f"FAIL: stale exemption {name}: it now has a links[] entry", file=sys.stderr)
        elif name not in calls:
            fail = True
            print(f"FAIL: stale exemption {name}: no skill or routine runs it by bare name", file=sys.stderr)
    if fail:
        print("Fix: add {source: bin/<name>, target: $HOME/.local/bin/<name>} to the last-stack "
              "links[], call it by full path, or add a reasoned line to "
              "tests/fixtures/host-track-links-bare-exempt.txt.", file=sys.stderr)
        return 1
    print(f"ok last-stack-host-track-links-bare-helpers bare={len(calls)} exempt={len(exempt)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
