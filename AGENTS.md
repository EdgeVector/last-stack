<!-- last-stack:generated-evidence:start (managed by last-stack setup; edits inside are overwritten) -->
## Keep raw evidence outside Git (Tom, 2026-10-23)

- Do not commit raw logs, timing samples, request/reply dumps, generated receipts, or compressed copies.
- This rule overrides an older instruction to commit every proof file or preserve raw output in Git.
- Keep raw output outside the source tree, under `LAST_STACK_EVIDENCE_ROOT` when set.
- The default root is `${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/artifacts/<repo>/`.
- Use a unique directory for each run. Benchmark defaults must use this root or the CI runner's temporary directory.
- Add ignored output directories as a local guard. An ignore rule does not exempt a committed file from CI.
- Commit a short Markdown report, useful source scripts, and an optional compact `artifact.json`.
- State the result, method, source revisions, commands, and limits in the report.
- Upload raw output as a workflow artifact. Use a durable archive when review or recovery needs long retention.
- Record the download URL, SHA-256, source revision, and retention period. Verify the upload before local cleanup.
- Keep secrets out of reports, receipts, and uploaded output.
- A PR permits at most 10 changed evidence files and 100,000 total evidence bytes.
- The required `generated-evidence` check reads committed files. Force-add and compression do not override it.
- Unchanged historical output and deletions do not count. Product JSON configuration remains permitted.
- An intentional product data exception needs an exact path and a reason in the accepted base policy.
- Do not weaken the check, split output across small files, or move it to another PR to evade the rule.

Policy and receipt format: `https://github.com/EdgeVector/.github/tree/main/generated-evidence`.
<!-- last-stack:generated-evidence:end -->

# No tests in EdgeVector repos (Tom, 2026-10-09)

Situation: `no-tests-all-repos-20261009`.

Tom deleted the tests and withdrew all test requirements in every repo.
This instruction supersedes earlier test, fixture, mutation-probe, and test coverage requirements.

- Do not write, restore, add, repair, run, or require tests.
- Remove existing tests when you find them in a repo that you change.
- Remove test commands and test coverage requirements from CI, linters, skills, prompts, cards, and repo instructions.
- Do not replace deleted tests with a new test suite or a fixture harness.
- Keep format, syntax, lint, build, security, and real operational checks.
- Use the app, the command, or the live signal for required product proof.
- A source check is a source check. It does not prove the live result.
- Do not bypass a non-test gate. Re-enable tests only if Tom gives a new instruction.
