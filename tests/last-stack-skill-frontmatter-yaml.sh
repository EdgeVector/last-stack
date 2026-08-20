#!/usr/bin/env bash
# Skill frontmatter must be strict YAML so agy can load it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
python3 - "$ROOT/skills" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
fails = []
ok = 0
for path in sorted(root.rglob("SKILL.md")):
    text = path.read_text()
    if not text.startswith("---"):
        continue
    parts = text.split("---", 2)
    if len(parts) < 3:
        fails.append(f"{path}: missing closing ---")
        continue
    try:
        import yaml
    except ImportError:
        # No PyYAML: reject unquoted mapping-value colons in description.
        body = parts[1]
        for i, line in enumerate(body.splitlines(), 1):
            if line.startswith("description:") and not line.startswith("description: |") and not line.startswith("description: >"):
                rest = line[len("description:"):].lstrip()
                if rest and not (rest[:1] in "\"'"):
                    if ": " in rest:
                        fails.append(f"{path}:{i}: unquoted colon in description")
        ok += 1
        continue
    try:
        yaml.safe_load(parts[1])
        ok += 1
    except Exception as exc:
        fails.append(f"{path}: {exc}")
if fails:
    print("FAIL skill frontmatter:", file=sys.stderr)
    for item in fails:
        print(item, file=sys.stderr)
    sys.exit(1)
print(f"ok last-stack-skill-frontmatter-yaml skills={ok}")
PY
