# GitHub is the gate of record

`EdgeVector/last-stack` moved to GitHub on 2026-09-30 (brain:
`decision-2026-09-29-retire-lastgit-all-repos-to-github`).

- `ci-required.yml`: the `lint` job runs `.lastgit/ci.sh` (bash -n and the
  global lint passes) on `macos-latest`. The repo has no tests (deleted
  2026-10-09). The final job `ci-required` is the required check. `publish`
  runs on a push to main and uploads the host-track artifact.
- `host-track-artifact.yml`: reusable workflow. Other EdgeVector repos call it as
  `EdgeVector/last-stack/.github/workflows/host-track-artifact.yml@main`. Do not
  rename the file, its inputs, or the `ht-artifact-<sha>` artifact name.

Open PRs on GitHub with `gh pr create` and arm auto-merge (`gh pr merge --auto
--squash`). The LastGit and Forgejo copies are frozen. See `.last-stack/pr-venue`.
