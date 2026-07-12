---
type: reference
slug: workspace-config
title: Workspace Config - <PROJECT_NAME> routine constants
status: active
tags: routines, portability, config
---
# Workspace Config - <PROJECT_NAME>

Project-level constants that scheduled routines read instead of hard-coding
paths, service endpoints, and local guardrails. Keep this record factual and
machine-readable enough for agents to parse. If your project already has a
dedicated config app, seed these fields there and leave this brain record as a
pointer to that source.

<!-- Project display name. Example: Acme Platform. -->
- **project_name**: `<PROJECT_NAME>`

<!-- Absolute directory that contains the project's repo checkouts. This may be a
workspace folder and does not need to be a git repo. -->
- **workspace_root**: `<WORKSPACE_ROOT>`

<!-- Human owner or team responsible for irreversible decisions. -->
- **owner**: `<OWNER_NAME_OR_TEAM>` (`<OWNER_CONTACT>`)

<!-- Brain data-plane endpoint. Prefer a Unix socket path. Do not put secrets
here. -->
- **primary_brain**: `<BRAIN_DAEMON_NAME>` on `<BRAIN_SOCKET_PATH>`

<!-- Names or paths agents must never restart, reset, or kill. -->
- **never_touch**: `<PRIMARY_BRAIN_GUARDRAIL>, <FORGE_SERVICE_GUARDRAIL>, <OTHER_GUARDRAIL>`

<!-- Forge or code-review service used by local/private repos. For public GitHub
repos, keep the GitHub venue in repo-venue-map instead. -->
- **forge_url**: `<FORGE_URL>`

<!-- Secret locator, not a raw token. Use lastsecrets://... or your equivalent. -->
- **forge_token_ref**: `<FORGE_TOKEN_REF>`

<!-- Board CLI command. Include the exact command name agents should preflight. -->
- **board_cli**: `<BOARD_CLI>`

<!-- Brain CLI command. Include the exact command name agents should preflight. -->
- **brain_cli**: `<BRAIN_CLI>`

<!-- Optional posture/preflight CLI. Use "none" when the project does not have one. -->
- **situations_cli**: `<SITUATIONS_CLI_OR_NONE>`

<!-- Directory reserved for isolated task worktrees. Agents should never edit the
shared checkout in place. -->
- **agent_worktree_dir**: `<AGENT_WORKTREE_DIR>`

<!-- Where scheduled-agent transcripts or logs live, if session-mining routines
are enabled. -->
- **session_transcripts**: `<SESSION_TRANSCRIPTS_PATH>`

<!-- Where scheduled routine prompt/config files live. -->
- **scheduled_tasks_dir**: `<SCHEDULED_TASKS_DIR>`

<!-- Repos or paths agents may inspect but must not push or mutate. -->
- **archived_or_hands_off_repos**: `<REPO_OR_PATH_1>, <REPO_OR_PATH_2>`

<!-- PATH prefix used by scheduled shells before CLI preflight. -->
- **path_prefix**: `export PATH="<PATH_PREFIX>:$PATH"`

## Bootstrap checks

- `<BOARD_CLI> list` succeeds against the intended board.
- `<BRAIN_CLI> get workspace-config` returns this record.
- A routine can resolve `<WORKSPACE_ROOT>` to child repos without treating the
  workspace root itself as a repo.
