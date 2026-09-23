## Agent shell on this host: the rules a guard enforces

A scheduled Codex routine command runs in **bash 5**. Codex starts
`/bin/zsh -lc`, and the last-stack block in `~/.zprofile` hands the command to
bash. A Claude Code Bash command runs in **zsh**. Before the command runs,
`last-stack-routine-shell-lint` checks it. A rejection prints the rule and the
fix, and the command does not run.

- A rejection is the guard working. **Do not file a papercut for it.** Rewrite
  the command and run it again.
- Escape hatch, only for an intended shape: `# shell-lint-ok: <reason>`.

| Rule | Fails because | Write this instead |
|---|---|---|
| spin-wait | `read -t N < /dev/zero` returns at once and burns a core | `sleep 30` (Codex); in Claude Code, one check per turn |
| heredoc-backticks | `<<EOF` runs the backticks in a Markdown body | `cat > "$f" <<'EOF'`, then `--body "$(cat "$f")"` |
| jq-optional-call | host jq 1.7.1 rejects `match(..)?.string` and `(.a)?.b` | `try (match("re").string) catch ""` |
| jq-escaped-quote | `\"` inside `\( )` is a jq syntax error | `[.slug, .status, (.severity // "-")] \| @tsv` |
| awk-match-array | macOS awk has no `match(s, /re/, arr)` | `sed -n 's/^KEY:[[:space:]]*//p' file` |
| sed-inplace | macOS `sed -i` takes the next word as an extension | `sed -i '' 's/a/b/' file` |
| zsh-status (Claude) | `status` is read-only in zsh | `rc`, `pr_state`, `ci_state` |
| zsh-mapfile (Claude) | zsh has no `mapfile` | `while IFS= read -r x; do ...; done < "$file"` |

Two more hazards that no guard can see:

- A TSV `read` with `IFS=$'\t'` collapses empty fields and shifts the next
  columns. Emit `-` for an empty field (`(.x // "-")`), or keep the JSON.
- `jq -r '[inputs ...]' a.json b.json` skips the first file. Use `jq -s`.

Helpers that remove the hand-written parse:

- `last-stack-kanban-done-when-sweep`: the DONE-WHEN sweep, one TSV row per
  card with no empty field.
- `last-stack-json-capture <file> -- <cmd> --json`, then `jq` the file.
- The Codex exec guard rejects any `rm -f` / `rm -rf`. Put scratch files in
  `mktemp` paths under `$TMPDIR` and do not clean up. The run-dir prune removes
  them.
