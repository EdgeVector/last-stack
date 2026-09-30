# last-stack LaunchAgents

Most units are last-stack host jobs. Since 2026-09-30 `last-stack` itself is
gated on GitHub (`.github/workflows/ci-required.yml`). The LastGit
`artifact-release` unit is retired: the `publish` job uploads the Actions
artifact and `host-track refresh last-stack` pulls it.

The text below describes the LastGit fleet supervisor that still serves the
repos that remain on LastGit or Forgejo:

```
com.edgevector.lastgit-forge-primary
lastgit forge run --all --context ci-required
```

That process covers every home on the node, including `last-stack`. Do **not**
add a `lastgit ci watch --repo last-stack --context ci-required` unit here. A
second watcher on the same (repo, context) duplicates `LastgitRefEvent` reads
and bypasses `--max-per-repo-concurrency`.

Check coverage with `bin/last-stack-lastgit-ci-coverage --repo last-stack`
(add `--head <oid>` to ask about one commit). The sibling
`ci watch` processes on this host are deploy/artifact contexts
(`deploy-prod`, `deploy-pipeline`, `artifact-release`), not `ci-required`.
