## Agent shell on this host: the rules a guard enforces

A scheduled Codex routine command runs in **bash 5**. Codex starts zsh, and
the last-stack block in `~/.zshenv` hands the command to bash. A Claude Code Bash command runs in **zsh**. Before the command runs,
`last-stack-routine-shell-lint` checks it. A rejection prints the rule and the
fix, and the command does not run.

- A rejection is the guard working. **Do not file a papercut for it.** Rewrite
  the command and run it again.
- Escape hatch, only for an intended shape: `# shell-lint-ok: <reason>`.

| Rule | Fails because | Write this instead |
|---|---|---|
| spin-wait | `read -t N < /dev/zero` returns at once and burns a core | `sleep 30` (Codex); in Claude Code, one check per turn |
| heredoc-backticks | `<<EOF` runs the backticks in a Markdown body | `cat > "$f" <<'EOF'`, then `--body "$(cat "$f")"` |
| dquote-backticks | `--body "...`x`..."` runs `x` | the same body file, or single quotes |
| jq-optional-call | host jq 1.7.1 rejects `match(..)?.string` and `(.a)?.b` | `try (match("re").string) catch ""` |
| jq-escaped-quote | `\"` inside `\( )` is a jq syntax error | `[.slug, .status, (.severity // "-")] \| @tsv` |
| awk-match-array | macOS awk has no `match(s, /re/, arr)` | `sed -n 's/^KEY:[[:space:]]*//p' file` |
| sed-inplace | macOS `sed -i` takes the next word as an extension | `sed -i '' 's/a/b/' file` |
| date-nanos | macOS `date` has no `%N` | `gdate +%s%3N` |
| printf-dash | `printf '- x'` reads `-` as an option | `printf '%s\n' '- x'` |
| bin-path | `/bin/mktemp` does not exist on macOS | `mktemp` or `/usr/bin/mktemp` |
| zsh-status (Claude) | `status` is read-only in zsh | `rc`, `pr_state`, `ci_state` |
| zsh-mapfile (Claude) | zsh has no `mapfile` | `while IFS= read -r x; do ...; done < "$file"` |

Hazards that no guard can see:

- The Codex routine shell is already bash. Do not wrap a command in
  `bash -lc '...'`: the nested single quotes break `$'\t'`, heredocs and
  backticks.
- In bash, `cmd | while read x; do n=$((n+1)); done` runs the loop in a
  subshell, so `n` is 0 after it. Read from a file: `done < "$f"`.
- A file name that starts with `-` is read as an option (`jq . -x.json`
  prints help). Prefix it with `./` or keep scratch names plain.
- Put captures in a fresh `mktemp -d "$TMPDIR/x.XXXXXX"` dir, not
  `/tmp/<name>-*.json`: a glob over /tmp mixes in files from old runs.

- A TSV `read` with `IFS=$'\t'` collapses empty fields and shifts the next
  columns. Emit `-` for an empty field (`(.x // "-")`), or keep the JSON.
- `jq -r '[inputs ...]' a.json b.json` skips the first file. Use `jq -s`.

Helpers that remove the hand-written parse:

- `last-stack-kanban-done-when-sweep`: the DONE-WHEN sweep, one TSV row per
  card with no empty field.
- `last-stack-json-capture <file> -- <cmd> --json`, then `jq` the file.
- One card field, no hand-written filter:
  `kanban show <slug> --json | last-stack-json-get .body` (also `.tags`,
  `.column`). `kanban show` gives one object; `kanban list` gives
  `{cards: [...]}`; do not mix the two shapes in one `jq` call.
- The Codex exec guard (inside the Codex app) rejects any `rm -f` / `rm -rf`.
  Put scratch files in `mktemp` paths under `$TMPDIR` and do not clean up; the
  run-dir prune removes them. That rejection is known too: do not file it.
- In Claude Code, `grep` is ugrep (shell snapshot function). A bounded-context
  regex such as `'.\{0,200\}word'` fails with "exceeds complexity limits" and
  looks like no match. Use `/usr/bin/grep` or `rg -o '.{0,200}word'`.
- Codex JavaScript (code mode) tools: a shell command inside a JS template
  literal loses `${var}` to JavaScript. Pass the command as a plain quoted
  string, or write `\${var}`.
- `rg` over state or log roots can print one 26 MB line. Add
  `--max-columns 300 --max-filesize 1M`; `head` limits lines, not bytes.
