## Batch LastDB calls: no serial calls (Tom, 2026-10-07)

LastDB works best when you batch calls as much as you can. This rule applies
to every agent, every routine, and every app code change.

- Collect all keys first. Then send one batch read by key.
- Collect all writes first. Then send one batch of mutations.
- Send independent calls in parallel in the same turn.
- Do not write a loop that sends one call for each record.
  Examples: `kanban show` in a loop, `brain get` in a loop, one mutation for each item.
- A scan does not exist. Batching does not replace keys. Batch keys, not scans.

CAUTION: Each call pays a fixed cost for the socket, the queue, and the ack.
A burst of serial calls loads the node. The node then returns `service_timeout`
or "too many concurrent reads". A batch pays the cost once.

Details: `brain get preference-lastdb-batch-calls-no-serial --type preference`.
The hourly routine `lastdb-batch-apps` changes one app each hour to use batch calls.
