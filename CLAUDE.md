# Last Stack Guardrails

- **Never kill Tom's primary LastDB brain.** Machine-hygiene reapers must identify
  the live brain by `/Users/tomtang/.lastdb/data/folddb.sock` first, use
  `/Users/tomtang/.folddb/data/folddb.sock` only as a stale-path fallback, or
  exclude the app-hosted brain with `pgrep -fl 'MacOS/[f]old-app'`. A long-lived
  `fold-app`, `lastdb_server`, or `folddb_server` process is not an orphan signal
  by itself.
