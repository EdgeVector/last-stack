# last-stack LaunchAgents

## Primary signed cloud snapshot

The primary Mac already runs `com.tomtang.lastdb-cloud-backup-kick` on
the cadence in its installed LaunchAgent. Its program path resolves to
`lastdb-cloud-backup-kick` from the Last Stack package. This job checks
the daemon's signed cloud status, then calls
`lastdb backup snapshot --database personal --wait` for the connected
production personal database. The daemon confirms publication and owns
the separate automatic log cleanup.

Read `cloud-backup/kick.log` under the Last Stack state directory.
`OK snapshot_through=<position>` records the published snapshot position.
A disconnected backup records `SKIP`. A daemon, capture, payment, or
snapshot error records `FAIL` and returns nonzero. Keep the existing
LaunchAgent schedule and use its normal invocation for live verification.

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

The sibling
`ci watch` processes on this host are deploy/artifact contexts
(`deploy-prod`, `deploy-pipeline`, `artifact-release`), not `ci-required`.
