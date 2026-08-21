# Ship spine (routines × kanban)

Tools:

- `bin/last-stack-design-pack` — required blueprint pack before proposing a design
- `bin/last-stack-kanban-decision-check` — bounded brain retrieval + mechanical refuse before a Kind:pr file; `last-stack-kanban-file-pr` runs it and stamps `## DECISION-CHECK`
- `bin/last-stack-ship-handoff` — post-approval NS + heading `## MILESTONE_REQUEST` + one milestone; walk away only on `eligible_for_claim: true`
- `bin/last-stack-real-human-notify` — page Tom for REAL_HUMAN only via `ra notify` (same argv as factory-health)
- `bin/last-stack-ship-preflight` — exit 0/1 walk-away check
- `bin/last-stack-why-shipping-stopped` — Class A-E stall diagnosis + heal
- `bin/last-stack-fleet-deadman` — out-of-band routinesd + heartbeat staleness
- `kanban pickup explain <slug>` — full readiness path (fkanban)

Install deadman (optional): copy
`templates/launchd/com.edgevector.fleet-deadman.plist.example` to
`~/Library/LaunchAgents/com.edgevector.fleet-deadman.plist`, fix paths, then
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.edgevector.fleet-deadman.plist`.

See brain `preference-tom-high-autonomy-operating-system` and
`reference-routines-kanban-interoperation-guide`.
