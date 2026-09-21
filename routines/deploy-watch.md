---
name: deploy-watch
cadence: every 5 minutes
description: Deploy every enabled repo whose forge main moved to a green commit, through the durable deploy-main Loom graph.
---

You run the deploy watcher. It is zero-agent: the gate does the work and
prints the result. You relay it.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" jq git loom
export PATH="$last_stack/bin:$HOME/.local/bin:$PATH"
```

## Execute

```bash
"$last_stack/bin/last-stack-deploy-watch-gate"
```

For each enabled repo in `config/deploy/repos.json` the gate reads the forge
`main` tip. When the tip moved and its Forge CI status is `success`, it runs
`last-stack-deploy-loom --repo <name> --oid <tip>`: the `deploy-main` Loom
graph stages that exact commit, runs the repo's own deploy script (a checked
effect — a resumed execution does not deploy twice), runs the repo's verify
command, and posts the `deploy-prod` status on the commit.

One line per repo: `current@…`, `deployed@…`, `ci_pending@…`, `ci_failure@…`,
`held_after_failure@…`, `disabled`. A failed deploy is reported once and then
held until a new commit or a human re-runs the launcher after the fix.

Do not run a repo's deploy script by hand from this routine. Do not enable a
disabled repo here; that is a config change with its own PR.

## Closeout

Print the gate result. End with the heartbeat and one `ROUTINE_RESULT` line
(the gate already printed one; repeat it).
