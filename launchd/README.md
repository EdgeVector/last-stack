# last-stack LaunchAgents

These units are last-stack host jobs (board closeout, factory health,
self-upgrade, host-track refresh). They are not LastGit CI.

Last-stack `ci-required` is served by the LastGit fleet supervisor:

```
com.edgevector.lastgit-forge-primary
lastgit forge run --all --context ci-required
```

That process covers every home on the node, including `last-stack`. Do **not**
add a `lastgit ci watch --repo last-stack --context ci-required` unit here. A
second watcher on the same (repo, context) duplicates `LastgitRefEvent` reads
and bypasses `--max-per-repo-concurrency`.

Check coverage with `bin/last-stack-lastgit-ci-coverage`. The sibling
`ci watch` processes on this host are deploy/artifact contexts
(`deploy-prod`, `deploy-pipeline`, `artifact-release`), not `ci-required`.
