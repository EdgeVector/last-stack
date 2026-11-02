---
name: last-stack-upgrade
description: Upgrade Last Stack skills and shared commands through the signed app registry.
---

# Last Stack upgrade

Read `lastdb app status last-stack --check --json`, then run
`lastdb app upgrade last-stack`. Review any changed install consent before
accepting it. The app's registry hook updates compatibility code links and
re-registers harness skills while preserving existing services and state.

Verify the installed source and probes with `lastdb app status last-stack --check
--json`. Use `lastdb app rollback last-stack` if a compatible prior version is
needed. Do not develop, reset, pull or commit in the installed source tree.
Code changes belong in an isolated worktree and must pass normal CI and merge
gates before registry publication. Other apps use `app-safe-upgrade`.
