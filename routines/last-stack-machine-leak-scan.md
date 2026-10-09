---
name: last-stack-machine-leak-scan
cadence: daily
description: Zero-LLM scan — ensure Last Stack public tree has no new host-machine identity leaks (paths, usernames, emails, private IPs).
---

# last-stack-machine-leak-scan

**Zero-LLM.** Prefer the LaunchAgent
`com.edgevector.last-stack-machine-leak-scan` (install via
`last-stack-machine-leak-scan-install`). This prompt is for agents asked to
run the same gate by hand.

## Why

Last Stack is a **public installable product**. Host usernames
(`/Users/<you>/…`), personal emails, and private VPN IPs must not ship in
the Git tree or the artifact that other machines install.

## Do

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude" 2>/dev/null || true
"$last_stack/bin/last-stack-machine-leak-scan"
"$last_stack/bin/last-stack-lint-machine-leaks" --report
```

- On **ok**: heartbeat and exit.
- On **fail**: do **not** ship product in this pass. Read `global_token=` in the
  heartbeat line first.
  - `global_token=clean`: File or update a single `Kind: pr` card on
    `EdgeVector/last-stack` to scrub the **new** soft debt (or hard findings),
    referencing `bin/last-stack-lint-machine-leaks`. Dedupe first.
  - `global_token=found|unreadable|error`: this is a host problem, not a code
    scrub. Do not file a `Kind: pr` card. Do not run
    `last-stack-scrub-github-token-remotes --global` yourself: it edits the
    user's `~/.gitconfig`. Report the state and wait for Tom. See below.

## Global git token check

The scan runs `last-stack-scrub-github-token-remotes --check --global /var/empty`.
It looks for `[url "https://<token>@github.com/"] insteadOf = https://github.com/`
in every git config source outside a repo. That rewrite puts the token in every
`git remote -v`, push line and git error on the host.
(`papercut-fold-git-remote-url-embeds-credential-20261001`)

| `global_token` | Meaning |
|---|---|
| `clean` | git read every config source and found no rewrite. |
| `found` | A rewrite exists, or git expands one from a file the tool does not edit (XDG file, included file, system file, `GIT_CONFIG_COUNT`). |
| `unreadable` | git could not read its config. The scan could not look. |
| `error` | The scrub tool is missing or too old to know `--global`. |

Anything but `clean` makes the scan fail. The scan never writes the tool output
to a log. Tom fixes the host: run `last-stack-scrub-github-token-remotes --check --global /var/empty`,
edit any file the tool names, then rotate the token through LastSecrets.
Removing the rewrite does not revoke a token that agent transcripts already hold.

## Related

- No local machine identity in shipped git: no home paths, hostnames or
  usernames in tracked files
- Installable-product hygiene: the install tree carries nothing host-specific
- CI: `.lastgit/ci.sh` runs `last-stack-lint-machine-leaks --ci`
