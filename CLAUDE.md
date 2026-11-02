<!-- last-stack:generated-evidence:start (managed by last-stack setup; edits inside are overwritten) -->
## Keep raw output outside Git (Tom, 2026-10-23)

- Do not commit raw logs, samples, request/reply dumps, generated receipts, or compressed copies.
- Use the CI summary and artifacts as the validation record. Link the run in the PR.
- Do not create a separate report or `artifact.json` for routine CI. This rule replaces older proof-file requirements.
- Keep useful source scripts and durable design conclusions in Git. Optional evidence files have a cap of 10 files and 100,000 bytes per PR.
- CI keeps raw output in the runner's temporary directory. Other output uses a unique directory outside Git. Use `LAST_STACK_EVIDENCE_ROOT`, or `${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/artifacts/<repo>/`.
- CI records the source revision, download URL, checksum, and expiration. Archive selected results when long retention is necessary.
- Keep secrets out of all output. Verify retained output before cleanup.
- Keep the required `generated-evidence` check and output ignores. Do not evade the check. Product-data exceptions require an exact path and reason in the accepted base policy.

Policy: https://github.com/EdgeVector/.github/tree/main/generated-evidence.
<!-- last-stack:generated-evidence:end -->

# Last Stack Guardrails

- **Never kill Tom's primary LastDB brain.** Machine-hygiene reapers must identify
  the live brain by `/Users/REPLACE/.lastdb/data/folddb.sock`, or exclude the
  app-hosted brain with `pgrep -fl 'MacOS/[f]old-app'`. A long-lived
  `fold-app`, `lastdb_server`, or `folddb_server` process is not an orphan signal
  by itself.

- **Never print a raw environment.** `env`, `printenv`, `export -p` and
  `env | grep -E 'CARGO|RUST|FOLD'` write every exported credential into the
  run log and the chat transcript. That is how a raw OpenRouter key reached
  both on 2026-08-18. Use
  `bin/last-stack-env-dump` instead — same output, secret-shaped names masked —
  or pipe any diagnostic through `bin/last-stack-mask-secrets`. To hand a
  credential to one child process, resolve it at exec time with
  `bin/last-stack-secret-env-run --env NAME --ref lastsecrets://SLUG -- CMD`;
  the caller then holds a locator, not a value.

- **No tests in any EdgeVector repo (Tom, 2026-10-09).** Read
  `instructions/no-tests.md`. Do not write, restore, or run tests. Remove test
  and test coverage requirements when you find them. Keep syntax, format,
  lint, build, security, and real operational checks.
  Situation: `no-tests-all-repos-20261009`.
