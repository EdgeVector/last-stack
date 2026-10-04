#!/usr/bin/env bash
# Regression test for bin/last-stack-verify-skill-links under a TRANSIENT
# source tree (a git worktree under .fkanban/worktrees).
#
# Why this file exists separately from last-stack-verify-skill-links.sh: that
# test builds a canonical $HOME/.last-stack clone and installs from a scratch
# worktree OF it, so `setup` resolves SOURCE_ROOT to the canonical checkout and
# every link is a symlink. It therefore has full coverage of the canonical path
# and none of the transient one — and the transient path is where the defect
# lived. `setup`'s _link_or_copy COPIES when the source is transient, because a
# symlink into a reapable worktree dangles; the verifier did not share that
# rule, so it called each deliberate copy "a foreign installer claimed skill
# name" and then re-pointed it into the worktree — the exact state
# assert_safe_skill_links refuses. Measured 2026-10-04 on main 9e3c6ffa7: 39
# COLLISION lines and 39 such repairs per worktree-sourced `setup` run.
# Brain: papercut-last-stack-setup-claude-permissions-test-var-private-var-collision-20260923
#
# No git is needed: both the installer and the verifier classify a path under
# */.fkanban/worktrees/* as transient by pattern.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GUARD="$ROOT/bin/last-stack-verify-skill-links"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

export HOME="$tmp/home"
mkdir -p "$HOME/.claude/skills"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Optional positional case filter, e.g. `... 4` to run only case 4. Every case
# below sets up its own installed state, so any one runs alone.
#
# This exists for MUTATION PROBES, and it is not cosmetic. The cases share one
# predicate, and case 2 (a stale copy must be drift) is the easiest of them to
# fail — so every over-permissive mutation trips case 2 first and the probe's
# RED says nothing about the case it was aimed at. Without a filter, cases 4 and
# 1 have no independent verdict available at all.
ONLY="${1:-}"
case_enabled() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# A minimal Last Stack source tree at $root with one skill named $2.
make_source() {
  local root="$1" name="$2"
  mkdir -p "$root/skills/$name"
  printf '0.0.0-test\n' > "$root/VERSION"
  printf -- '---\nname: %s\ndescription: fixture\n---\nbody v1\n' "$name" \
    > "$root/skills/$name/SKILL.md"
}

TRANSIENT_SRC="$tmp/wt/.fkanban/worktrees/last-stack-kanban-fixture"
CANONICAL_SRC="$tmp/canonical"
make_source "$TRANSIENT_SRC" diagram
make_source "$CANONICAL_SRC" diagram

SKILL_MD="$HOME/.claude/skills/diagram/SKILL.md"
mkdir -p "$(dirname "$SKILL_MD")"

run_guard() { # run_guard <src_root> [extra flags...] -> rc in $rc, output in $out
  local src="$1"; shift
  out="$tmp/guard.out"
  rc=0
  LAST_STACK_ROOT="$src" "$GUARD" "$@" "$HOME/.claude/skills" >"$out" 2>&1 || rc=$?
}

# ── 1. transient source + content-matching COPY is the CORRECT state ──────────
if case_enabled 1; then
  cp -f "$TRANSIENT_SRC/skills/diagram/SKILL.md" "$SKILL_MD"
  run_guard "$TRANSIENT_SRC"
  [ "$rc" -eq 0 ] || { cat "$out" >&2; fail "case 1: a correct transient copy exited $rc"; }
  grep -q COLLISION "$out" && { cat "$out" >&2; fail "case 1: a deliberate copy was reported as a foreign-installer COLLISION"; }
  grep -q 'repaired:' "$out" && { cat "$out" >&2; fail "case 1: a correct transient copy was repaired"; }
  [ -L "$SKILL_MD" ] && fail "case 1: the guard turned a correct copy into a symlink"

  # --check must agree and must change nothing.
  before="$(cat "$SKILL_MD")"
  run_guard "$TRANSIENT_SRC" --check
  [ "$rc" -eq 0 ] || { cat "$out" >&2; fail "case 1: --check reported drift on a correct transient copy"; }
  [ "$(cat "$SKILL_MD")" = "$before" ] || fail "case 1: --check modified the installed SKILL.md"
fi

# ── 2. transient source + STALE copy is drift, repaired back to a COPY ───────
if case_enabled 2; then
  printf 'stale body\n' > "$SKILL_MD"
  run_guard "$TRANSIENT_SRC"
  [ "$rc" -eq 0 ] || { cat "$out" >&2; fail "case 2: repair run exited $rc"; }
  grep -q 'repaired:' "$out" || { cat "$out" >&2; fail "case 2: a stale transient copy was not repaired"; }
  [ -L "$SKILL_MD" ] && fail "case 2: repair under a transient source produced a SYMLINK into the worktree"
  cmp -s "$SKILL_MD" "$TRANSIENT_SRC/skills/diagram/SKILL.md" \
    || fail "case 2: repaired copy does not match the transient source"
fi

# ── 3. the hazard the old guard CREATED: a link into the transient tree ──────
if case_enabled 3; then
  # This is the state a pre-fix repair left behind. The guard must now detect it
  # and heal it back to a copy, not accept it and not recreate it.
  ln -snf "$TRANSIENT_SRC/skills/diagram/SKILL.md" "$SKILL_MD"
  run_guard "$TRANSIENT_SRC" --check
  [ "$rc" -ne 0 ] || { cat "$out" >&2; fail "case 3: --check accepted a symlink into a transient source tree"; }
  grep -q 'transient source tree' "$out" \
    || { cat "$out" >&2; fail "case 3: the message does not name the transient-link hazard"; }
  run_guard "$TRANSIENT_SRC"
  [ "$rc" -eq 0 ] || { cat "$out" >&2; fail "case 3: repair run exited $rc"; }
  [ -L "$SKILL_MD" ] && fail "case 3: the guard left a symlink into a reapable worktree"
  cmp -s "$SKILL_MD" "$TRANSIENT_SRC/skills/diagram/SKILL.md" \
    || fail "case 3: healed file does not match the transient source"
fi

# ── 4. a REAL foreign stomp is still caught under a transient source ─────────
if case_enabled 4; then
  # The whole point of the guard. Accepting the transient copy must not blind it.
  foreign="$tmp/gstack/skills/diagram"
  mkdir -p "$foreign"
  printf -- '---\nname: diagram\ndescription: mermaid stub\n---\n' > "$foreign/SKILL.md"
  ln -snf "$foreign/SKILL.md" "$SKILL_MD"
  run_guard "$TRANSIENT_SRC" --check
  [ "$rc" -ne 0 ] || { cat "$out" >&2; fail "case 4: --check missed a foreign installer stomp under a transient source"; }
  run_guard "$TRANSIENT_SRC"
  [ "$rc" -eq 0 ] || { cat "$out" >&2; fail "case 4: repair run exited $rc"; }
  [ -L "$SKILL_MD" ] && fail "case 4: a foreign stomp was repaired into a symlink under a transient source"
  cmp -s "$SKILL_MD" "$TRANSIENT_SRC/skills/diagram/SKILL.md" \
    || fail "case 4: foreign stomp was not replaced by the transient source content"
fi

# ── 5. the CANONICAL path is unchanged: a copy there is still drift ──────────
if case_enabled 5; then
  # Pins that the transient branch did not widen to a canonical source, where a
  # symlink is correct and a copy means some other installer wrote the file.
  rm -f "$SKILL_MD"
  cp -f "$CANONICAL_SRC/skills/diagram/SKILL.md" "$SKILL_MD"
  run_guard "$CANONICAL_SRC" --check
  [ "$rc" -ne 0 ] || { cat "$out" >&2; fail "case 5: --check accepted a plain copy under a CANONICAL source"; }
  run_guard "$CANONICAL_SRC"
  [ "$rc" -eq 0 ] || { cat "$out" >&2; fail "case 5: repair run exited $rc"; }
  [ -L "$SKILL_MD" ] || fail "case 5: repair under a canonical source did not produce a symlink"
  # resolve_source_root canonicalizes with `pwd -P`, so compare against the
  # realpath: under $TMPDIR that is /private/var/... while $tmp reads /var/...
  canonical_real="$(cd "$CANONICAL_SRC" && pwd -P)"
  [ "$(readlink "$SKILL_MD")" = "$canonical_real/skills/diagram/SKILL.md" ] \
    || fail "case 5: canonical repair points at $(readlink "$SKILL_MD")"
fi

echo "ok"
