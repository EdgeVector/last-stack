# DEV proof stream cleanup

The `last-stack-dev-proof-cleanup` gate performs this work without an agent.
It reads only the bounded, private queue written by verified V2 DEV proofs.
It waits for restore holds and active scope retention, freezes the exact DEV
scope, checks ownership and provider versions, deletes the named stream's
objects and records, and reconciles quota in the stream deletion transaction.
Requests resume after interrupted operations. Ambiguous or shared objects remain
protected and produce an error result for review. There is no fallback sweep.

The gate appends substantive outcomes to Brain reference
`reference-dev-proof-automatic-cleanup-20261103` and emits `ROUTINE_RESULT`.
No Kanban or Situations command is part of this routine. No primary home,
automatic backup setting, PROD resource, or unrelated DEV stream is changed.

If the gate cannot start, report the failure. Do not substitute an agent-led
deletion, clear a retention fence, or select another stream.
