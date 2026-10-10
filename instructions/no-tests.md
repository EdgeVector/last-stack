## No tests or test coverage requirements (Tom, 2026-10-09)

Situation: `no-tests-all-repos-20261009`.
Decision: `decision-2026-10-09-retire-all-tests-and-test-coverage`.

Tom deleted the tests and withdrew all test requirements in every repo.
This instruction supersedes earlier test, fixture, mutation-probe, and test coverage requirements.

- Do not write, restore, add, repair, run, or require tests.
- Remove existing tests when you find them in a repo that you change.
- Remove test commands and test coverage requirements from CI, linters, skills, routines, prompts, cards, and repo instructions.
- Do not replace deleted tests with a new test suite or a fixture harness.
- Keep product code and non-test format, syntax, lint, build, secret, security, deployment, and real operational checks.
- Use the app, the command, or the live signal for required product proof.
- A source check is a source check. It does not prove the live result.
- Do not bypass a non-test gate. Re-enable tests only if Tom gives a new instruction.
- Keep the Situation active until Tom changes the rule.
