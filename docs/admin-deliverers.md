# Brain and Routines admin deliverers

Last Stack installs two hourly LaunchAgents that refresh the existing admin SPA
tabs without reviving the retired multi-app wrapper:

| Snapshot | LaunchAgent | RUN home |
|---|---|---|
| Brain | `com.edgevector.admin-brain-snapshot` | `~/.local/share/edgevector/admin-brain-snapshot/` |
| Routines | `com.edgevector.admin-routines-status` | `~/.local/share/edgevector/admin-routines-status/` |

Both use the enrolled kanban-consumer identity from
`~/.lastdb/admin-deliver-recipient.env`. The installer never copies identity
values into a plist, log, or repository.

```bash
last-stack-admin-deliver-install install
last-stack-admin-deliver brain --dry-run
last-stack-admin-deliver routines --dry-run
last-stack-admin-deliver-install status
```

Each RUN home contains `run.sh`, a rendered plist copy, a short README, and the
delivery logs. `setup` reinstalls the versioned runners and plists after a Host
Track refresh. Ops Terminal owns the corresponding launchd coverage rows.

The archived `com.edgevector.admin-multi-app-deliver` plist is intentionally
untouched.
