#!/usr/bin/env bash
# Regression test for bin/last-stack-verify-skill-links: a foreign installer
# (e.g. gstack) that stomps a same-named skill link must be detected by --check
# and restored by a repair run. Mirrors the card's deliberate `diagram`
# collision test.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

export HOME="$tmp/home"
canonical="$HOME/.last-stack"
scratch="$tmp/scratch-last-stack"

mkdir -p "$HOME/.claude"
git clone --quiet --no-local "$ROOT" "$canonical"
rsync -a --delete --exclude=.git "$ROOT/" "$canonical/"
git -C "$canonical" config user.email "last-stack-test@example.invalid"
git -C "$canonical" config user.name "Last Stack Test"
git -C "$canonical" add -A
if ! git -C "$canonical" diff --cached --quiet; then
  git -C "$canonical" commit --quiet -m "test current working tree"
fi
git -C "$canonical" worktree add --quiet "$scratch" HEAD

canonical_real="$(cd "$canonical" && pwd -P)"
guard="$canonical/bin/last-stack-verify-skill-links"
diagram_link="$HOME/.claude/skills/diagram/SKILL.md"
want="$canonical_real/skills/diagram/SKILL.md"

# Install from the scratch worktree; setup must resolve to the canonical source.
( cd "$scratch" && ./setup --host claude >"$tmp/setup.out" )

# 1. Fresh install: every link is canonical, --check passes.
if ! "$guard" --check "$HOME/.claude/skills" >"$tmp/check1.out" 2>&1; then
  echo "FAIL: --check reported drift on a fresh install" >&2
  cat "$tmp/check1.out" >&2
  exit 1
fi

# The diagram link must resolve into the Last Stack tree to begin with.
got="$(cd "$(dirname "$(readlink "$diagram_link")")" && pwd -P)/$(basename "$(readlink "$diagram_link")")"
if [ "$got" != "$want" ]; then
  echo "FAIL: fresh diagram link is $got, expected $want" >&2
  exit 1
fi

# 2. Simulate gstack stomping the `diagram` skill with its own SKILL.md.
fake_gstack="$tmp/gstack/skills/diagram"
mkdir -p "$fake_gstack"
printf -- '---\nname: diagram\ndescription: mermaid stub\n---\n' > "$fake_gstack/SKILL.md"
ln -snf "$fake_gstack/SKILL.md" "$diagram_link"

# 3. --check must now FAIL (drift/collision detected), non-zero exit.
if "$guard" --check "$HOME/.claude/skills" >"$tmp/check2.out" 2>&1; then
  echo "FAIL: --check did not detect the stomped diagram link" >&2
  cat "$tmp/check2.out" >&2
  exit 1
fi
grep -q "diagram" "$tmp/check2.out" || {
  echo "FAIL: --check output did not mention the drifted diagram skill" >&2
  cat "$tmp/check2.out" >&2
  exit 1
}

# 4. A repair run must restore the canonical target and exit 0.
if ! "$guard" "$HOME/.claude/skills" >"$tmp/repair.out" 2>&1; then
  echo "FAIL: repair run exited non-zero" >&2
  cat "$tmp/repair.out" >&2
  exit 1
fi

got="$(cd "$(dirname "$(readlink "$diagram_link")")" && pwd -P)/$(basename "$(readlink "$diagram_link")")"
if [ "$got" != "$want" ]; then
  echo "FAIL: after repair diagram link is $got, expected $want" >&2
  exit 1
fi
case "$(readlink "$diagram_link")" in
  *"/.last-stack/skills/diagram/"*) ;;
  *) echo "FAIL: repaired link does not point under .last-stack/skills/diagram/: $(readlink "$diagram_link")" >&2; exit 1 ;;
esac

# 5. --check is clean again after repair.
if ! "$guard" --check "$HOME/.claude/skills" >"$tmp/check3.out" 2>&1; then
  echo "FAIL: --check still reports drift after repair" >&2
  cat "$tmp/check3.out" >&2
  exit 1
fi

git -C "$canonical" worktree remove --force "$scratch"

echo "ok"
