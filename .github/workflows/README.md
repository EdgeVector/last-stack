# GitHub workflows

`EdgeVector/last-stack` uses these workflows. Open a pull request with `gh pr create`. The required checks are `ci-required` and `generated-evidence`.

## `ci-required.yml`

Triggers: pull request to `main`, push to `main`, and `workflow_dispatch`.

The `lint` job runs on `macos-latest`. It runs `.github/scripts/ci-toolchain.sh`, then `.lastgit/ci.sh`. That script checks shell syntax with `bash -n`, runs the named lint passes, and checks `config/factory-repair-contract.json` with `bin/last-stack-factory-repair-contract --local --json`. The repo has no tests. The final job `ci-required` is the required check. It succeeds only when `lint` succeeds.

Do not rename `.lastgit/ci.sh`. `ci-required.yml` calls that path.

## `generated-evidence.yml`

Triggers: pull request, merge group, and `workflow_dispatch`.

The `generated-evidence` job is a required check. It calls `EdgeVector/.github/generated-evidence` at `31b28c2a07e8ba7f80df6735579c7dc1050b9232`.

## `registry-app-package.yml`

Reusable `workflow_call`. It does not run on its own.

Inputs:

| Input | Default |
|---|---|
| `runs-on` | `ubuntu-24.04` |
| `setup-bun` | `false` |
| `build-command` | empty |
| `config` | `.last-stack/package.json` |
| `tools-ref` | `main` |

The pack step runs `python3 .last-stack-tools/bin/last-stack-app-package-build`. The uploaded artifact name is `registry-package-<sha>`, where `<sha>` is the caller commit.

Do not rename this file, these inputs, or the `registry-package-<sha>` artifact. `EdgeVector/loom` and `EdgeVector/lastseek` call this workflow from their `.github/workflows/ci-required.yml`. Their `scripts/registry-prepare.py` read that artifact.

## `registry-proof.yml`

Triggers: cron `7,37 * * * *` (every 30 minutes) and `workflow_dispatch`.

Jobs:

- `plan` reads the registry `next` index and decides whether a proof runs.
- `proof` builds the named LastDB source, runs the install smoke, and uploads `registry-proof-bundle-<run id>`. The bundle holds verdicts, candidate identities, and timings. It does not hold a binary.
- `report` opens or updates one GitHub issue for a red build, and closes that issue for a green build.

This workflow never signs and never opens a tap pull request. Signing stays on Tom's Mac.
