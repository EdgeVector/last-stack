# Last Stack Guardrails

- **Never kill Tom's primary LastDB brain.** Machine-hygiene reapers must identify
  the live brain by `/Users/REPLACE/.lastdb/data/folddb.sock` first, use
  `/Users/REPLACE/.folddb/data/folddb.sock` only as a stale-path fallback, or
  exclude the app-hosted brain with `pgrep -fl 'MacOS/[f]old-app'`. A long-lived
  `fold-app`, `lastdb_server`, or `folddb_server` process is not an orphan signal
  by itself.

- **Never print a raw environment.** `env`, `printenv`, `export -p` and
  `env | grep -E 'CARGO|RUST|FOLD'` write every exported credential into the
  run log and the chat transcript. That is how a raw OpenRouter key reached
  both on 2026-08-18 (brain
  `papercut-routine-shell-exports-raw-openrouter-secret`). Use
  `bin/last-stack-env-dump` instead — same output, secret-shaped names masked —
  or pipe any diagnostic through `bin/last-stack-mask-secrets`. To hand a
  credential to one child process, resolve it at exec time with
  `bin/last-stack-secret-env-run --env NAME --ref lastsecrets://SLUG -- CMD`;
  the caller then holds a locator, not a value.
