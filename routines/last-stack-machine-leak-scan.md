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
- On **fail**: do **not** ship product in this pass. File or update a single
  `Kind: pr` card on `EdgeVector/last-stack` to scrub the **new** soft debt
  (or hard findings), referencing `bin/last-stack-lint-machine-leaks`.
  Dedupe first.

## Related

- `preference-lastgit-no-local-identity-in-public-git`
- `preference-last-stack-no-machine-leaks` (installable product hygiene)
- CI: `.lastgit/ci.sh` runs `last-stack-lint-machine-leaks --ci`
