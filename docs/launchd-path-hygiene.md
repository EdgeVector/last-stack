# launchd agent PATH hygiene

Homebrew git under launchd on macOS 26.5.1 hits a CoreFoundation CF-init
SIGSEGV (`EXC_BAD_ACCESS` in `CFNotificationCenterAddObserver`) that Apple's
`/usr/bin/git` does not. Any `com.edgevector.*` launchd agent whose
`EnvironmentVariables:PATH` resolves `/opt/homebrew/bin` before `/usr/bin`
picks the crashy git whenever it spawns one.

This first surfaced in `lastgit-git-cf-segfault-storm` (LastGit's own
forge/mirror/host-refresh daemons, fixed via lastgit PR #66 + a direct-patch
pass on already-deployed per-repo plists their templates don't cover) and
recurred on ~13 other launchd agents on this machine that aren't generated
from any checked-in template — `admin-kanban-snapshot`,
`admin-multi-app-deliver`, `forgejo-runner`, `forgejo-runner-host`,
`forgejo-runner-host-exemem-infra`, `kanban-factory`, `lastdbd-bob`,
`ops-terminal-deliver`, `remote-learn`, `remote-notify-watch`,
`remote-rad-telegram`, `routines-hygiene`, `routines-web`, `routinesd`
(`launchd-agents-homebrew-path-order-sweep-20260718`).

## Audit

```bash
bin/last-stack-launchd-path-audit            # scan, report NEEDS_FIX/OK
bin/last-stack-launchd-path-audit --fix      # reorder PATH in place
bin/last-stack-launchd-path-audit --fix --reload   # + bootout/bootstrap each changed agent
```

Reorders `EnvironmentVariables:PATH` so `/usr/bin` sits immediately before
the first `/opt/homebrew/bin` entry, preserving every other entry's relative
order. Exit code (dry-run mode) is the count of agents still needing a fix,
capped at 99, so it's safe to gate a script on `last-stack-launchd-path-audit
|| fix-and-reload`.

`--reload` bootouts and bootstraps one agent at a time — reload agents that
front live work (`routinesd`, `forgejo-runner*`, `lastdbd-bob`) one at a time
and check the agent comes back healthy before moving to the next, same as
the LastGit pass.

No `com.edgevector.*` launchd agent on this machine should have
`/opt/homebrew/bin` ordered ahead of `/usr/bin`. Re-run the audit after
installing any new agent template.
