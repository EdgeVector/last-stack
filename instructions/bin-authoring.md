## New helper scripts: one language, no unbounded walk

These rules apply when you add a `bin/` command or a skill script.

### Why (recorded 2026-08-02)

An agent shipped one helper in four drafts. The first draft was a bash
wrapper with a Python program in a heredoc. The quoting, the env flags and
argparse fought each other. The second draft found its config with
`Path.rglob` under `~/.fkanban/worktrees`. That walk crosses ~20 checkouts
and their cargo `target/` trees. It ran for minutes, the task timed out, and
the timeout read as a product failure. Brain:
`papercut-agent-zero-llm-cli-bash-python-heredoc-rglob`.

### The rules

1. Write one file in one language. Use `#!/usr/bin/env python3` with
   argparse, or pure bash. Do not put a Python program in a bash heredoc.
2. Do not walk a workspace root to find a file. Take the path from an
   explicit `--flag`, an environment variable, or a short fixed candidate
   list. When a search is unavoidable, bound its depth and its time:

   ```bash
   last-stack-locate-file --name feature_catalog.toml \
     --env PRODUCT_FEATURE_CATALOG \
     --candidate ~/code/edgevector/fold/folddb_profile/feature_catalog.toml \
     --root ~/.fkanban/worktrees --maxdepth 3
   find ~/.fkanban/worktrees -maxdepth 3 -name feature_catalog.toml
   ```

3. Write a fixture test under `tests/` before you run the helper against the
   live board or brain.
4. Parse a format from the first byte. Do not require a leading newline
   before the first TOML table or the first YAML document.
5. After a rewrite, stop or ignore the background tasks of the old drafts.
   Their late FAIL lines are noise.

### The guards

- `bin/last-stack-lint-bin-authoring` runs in CI. It fails on an unbounded
  walk in `bin/`, `lib/`, `hooks/` or `skills/*/scripts/`, and on a new
  bash-heredoc Python nest in `bin/`. A deliberate bounded walk states its
  bound on the line: `# walk-ok: <reason>`.
- Under Claude Code the hook `~/.claude/hooks/no-unbounded-workspace-walk.sh`
  denies a depth-free `find`/`fd`/`tree` over a workspace root, and a Python
  `rglob`/`os.walk` over one. The deny message hands back the bounded form.
  Escape hatch, with a reason: `# walk-ok: <reason>`.
