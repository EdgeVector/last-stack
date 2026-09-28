# last-stack LaunchAgents

Most units are last-stack host jobs. The artifact-release unit is the one
LastGit CI exception. It publishes and promotes merged `last-stack` main.

Last-stack `ci-required` is served by the LastGit fleet supervisor:

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

Install `com.edgevector.lastgit-artifact-release-last-stack.plist` in the user
LaunchAgents directory. Its watcher runs `.lastgit/artifact-release.sh`.
