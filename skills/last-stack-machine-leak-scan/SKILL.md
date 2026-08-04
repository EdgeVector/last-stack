---
name: last-stack-machine-leak-scan
description: >
  Scan Last Stack for host-machine identity leaks (usernames, home paths,
  emails, private IPs) that must not ship in the public installable product.
  Use when asked to check leaks, privacy of last-stack, or installability.
---

# last-stack-machine-leak-scan

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-lint-machine-leaks" --report
"$last_stack/bin/last-stack-lint-machine-leaks" --ci   # fail on new debt
```

Write baseline only when intentionally recording a scrub:

```bash
"$last_stack/bin/last-stack-lint-machine-leaks" --write-baseline
```

Install daily LaunchAgent:

```bash
"$last_stack/bin/last-stack-machine-leak-scan-install"
```
