# Ship spine (routines × kanban)

Tools:

- `bin/last-stack-ship-preflight` — exit 0/1 walk-away check
- `bin/last-stack-fleet-deadman` — out-of-band routinesd + heartbeat staleness
- `kanban pickup explain <slug>` — full readiness path (fkanban)

Install deadman (optional): copy
`templates/launchd/com.edgevector.fleet-deadman.plist.example` to
`~/Library/LaunchAgents/com.edgevector.fleet-deadman.plist`, fix paths, then
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.edgevector.fleet-deadman.plist`.

See brain `preference-tom-high-autonomy-operating-system` and
`reference-routines-kanban-interoperation-guide`.
