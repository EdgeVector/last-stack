#!/usr/bin/env bash
# Ensure lastdb-safe-upgrade is packaged for multi-harness setup install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
skill="$ROOT/skills/lastdb-safe-upgrade"
skill_md="$skill/SKILL.md"
driver="$skill/scripts/safe-upgrade-lastdb.sh"

[ -f "$skill_md" ] || { echo "FAIL: missing $skill_md" >&2; exit 1; }
[ -f "$driver" ] || { echo "FAIL: missing $driver" >&2; exit 1; }
[ -x "$driver" ] || { echo "FAIL: driver not executable: $driver" >&2; exit 1; }

grep -q '^name:[[:space:]]*lastdb-safe-upgrade' "$skill_md" || {
  echo "FAIL: SKILL.md frontmatter name mismatch" >&2
  exit 1
}
# Must not hard-code Claude-only install path as the only driver location.
if grep -n 'bash ~/.claude/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh' "$skill_md" >/dev/null; then
  echo "FAIL: SKILL.md still hard-codes Claude-only driver path" >&2
  exit 1
fi
grep -q '\.last-stack/skills/lastdb-safe-upgrade' "$skill_md" || {
  echo "FAIL: SKILL.md should document last-stack install path" >&2
  exit 1
}
grep -q '\.codex/skills/lastdb-safe-upgrade' "$skill_md" || {
  echo "FAIL: SKILL.md should document Codex install path" >&2
  exit 1
}

# bash -n on driver
bash -n "$driver"

# setup --host codex would register this name (dry structure check)
name="$(grep -m1 '^name:' "$skill_md" | sed 's/^name:[[:space:]]*//' | tr -d '[:space:]')"
[ "$name" = "lastdb-safe-upgrade" ] || {
  echo "FAIL: resolved skill name '$name'" >&2
  exit 1
}

echo "OK: lastdb-safe-upgrade skill packaged for multi-harness setup"
