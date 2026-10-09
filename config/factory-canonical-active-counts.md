Repo: EdgeVector/loom
Kind: pr
Work-class: repair
Difficulty: hard
Base: main
North Star: north-star-portable-routine-fleet
Milestone: ms-factory-heal-via-state-machine

## GOAL
Report each current canonical active Loom execution once.

## END STATE
The installed status result counts each canonical active execution once.
Active means initializing, running, or waiting. A parked or terminal execution
does not count. The native read preserves the accepted-write Ledger for every
requested key. Missing, malformed, unresolved, or timed-out reads fail.
The result states that IDs absent from all three active status hashes are
outside this read.

## SCOPE
Change active_execution_summary and add bounded Store::get_many through the
existing native HashRangeKeys route. Keep field revisions and reconcile every
requested key, including a missing result. Keep membership, leases, execution
state, the Ledger format, and the primary Mini build.

## VALIDATION
Fixtures cover duplicates, stale terminal memberships, malformed/missing
canonical records, foreign/duplicate reply keys, and accepted-write state.
Run targeted RED probes for the new guards. The fixed factory proof compares
the official installed status result with bounded exact canonical reads.

Papercut: papercut-loom-active-summary-counts-terminal-duplicate-memberships-20261008
Keep-open: papercut-loom-execution-status-backlog-sweep-pending-20260928
Authority: decision-2026-10-08-factory-repair-slot-and-bounded-proof
