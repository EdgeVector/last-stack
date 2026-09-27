## Never walk the home root (macOS raises a privacy prompt and BLOCKS)

Do not point `find`, `fd`, `du`, `rg`, `grep`, `ls`, `tree` or `ncdu` at
`$HOME` itself. Do not read `~/Desktop`, `~/Documents`, `~/Downloads`,
`~/Pictures`, `~/Movies` or `~/Music`.

### Why (measured 2026-09-05)

macOS protects those folders with TCC. A routine agent is a child of
`routinesd`, so macOS attributes the access to the responsible process
`routines` and shows the owner a dialog: "routines would like to access files
in your Desktop folder". Two costs:

1. The owner gets a burst of dialogs. The `routines` binary is ad-hoc signed at
   a content-hashed path, so each new install is a new code identity and the
   dialogs come back after every upgrade.
2. **The command blocks until a human clicks it.** Three papercuts recorded the
   same stall and blamed a slow `find`: 6, 7 and 8 minutes in loom review,
   disk-reclaim and feature-prove. The dialog was the cause.

An unattended run that waits on a click looks like a hang.

### What to do instead

Name the root you actually need:

```bash
find "$HOME/code" -maxdepth 4 -name '<what>'
find "$HOME/.routines" "$HOME/.last-stack" "$HOME/.fkanban" -maxdepth 4 -name '<what>'
find "$HOME/.local/state/last-stack" -maxdepth 4 -name '<what>'
```

Proof and artifact paths are known, not searched:
`~/.last-stack/north-star-proofs`, `~/.last-stack/feature-proofs`,
`~/.local/state/last-stack/artifacts`, `~/.fkanban/worktrees`.

If you truly need the whole tree, prune the protected folders and say why:

```bash
find "$HOME" -maxdepth 4 \( -path "$HOME/Desktop" -o -path "$HOME/Documents" \
  -o -path "$HOME/Downloads" -o -path "$HOME/Pictures" -o -path "$HOME/Movies" \
  -o -path "$HOME/Music" -o -path "$HOME/Library" \) -prune -o -print 2>/dev/null \
  # home-scan-ok: pruned example, names the protected folders only to exclude them
```

Under Claude Code the hook `~/.claude/hooks/no-home-root-scan.sh` denies the bad
form and hands back the scoped one. Escape hatch, with a reason:
`# home-scan-ok: <reason>`.

**Codex routines are covered too (2026-09-27).** 78 of 80 registry routines run
under `harness = "codex"`, which never read this Claude Code hook — that gap is
why the same stall recurred (loom review, disk-reclaim, feature-prove) even
after the hook shipped. The shared `bin/last-stack-routine-shell-lint` (the one
source both Codex routines and Claude Code Bash calls run through, see
`instructions/routine-shell.md`) now carries the same check as rule
`home-root-scan`, so a Codex routine command gets the same rejection and fix
text before it runs. Either escape phrase works there too: `# shell-lint-ok:
<reason>` or `# home-scan-ok: <reason>`.
