---
name: repark-shared-checkouts
description: |
  Frequent, lightweight sweep that keeps every shared repo checkout under
  ~/code/edgevector/<repo> current with its venue remote (main = a read-only
  mirror, never edited in place). Split out of the daily
  last-stack-worktree-cleanup sweep because that only runs once a day, which
  let repos drift 40-50+ commits behind within a single day of fleet
  activity. This routine does nothing else -- no worktree pruning, no
  session cleanup, just the repark pass.
---

# repark-shared-checkouts — keep shared main checkouts current

## Situations

`situations notices --since 15m` — a matching notice (LastDB upgrade, stack
upgrade, cutover) means treat any git-op contention as expected fallout, not
an incident. Never restart lastdbd/folddb from this routine.

## The one job

```bash
"$HOME/.last-stack/bin/last-stack-repark-shared-checkouts" || true
```

This helper is already safe by design:
- venue-aware (fetches only the repo's actual venue remote — lastgit,
  forgejo, or github per `.last-stack/pr-venue` — never blindly `origin`)
- fast-forward only when a repo is `behind` and clean
- `FLAG`s (does not touch) any repo that is `ahead`, `diverged`, dirty, or
  has an in-flight git op (e.g. an `index.lock`)
- salvages any local edits to a branch before touching a checkout, never
  resets or discards uncommitted work
- never pushes

## Report

Heartbeat one line via the standard helper:

```bash
iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ff_count="$(<output above>)"   # count how many repos showed ff(N) this run
flag_count="$(<output above>)" # count how many repos showed FLAG this run
"$HOME/.last-stack/bin/last-stack-brain-append-heartbeat" \
  --line "repark-shared-checkouts $iso ok ff=$ff_count flag=$flag_count"
printf 'ROUTINE_RESULT outcome=ok detail=ff=%s flag=%s\n' "$ff_count" "$flag_count"
```

Use `ok` whenever the command completed (even if it fast-forwarded nothing —
"nothing to do" is a healthy result, not a noop worth filing anything about).
Only escalate (`needs-human` / file a card) if a repo shows the SAME `FLAG`
reason on 3+ consecutive fires — that means it is stuck, not just mid-edit —
and even then, file at most one card per stuck repo (dedupe against an
existing open card with the same repo name in the title before filing).

## Out of scope

Worktree pruning, session archiving, disk reclaim, branch deletion — all of
that stays on the daily `last-stack-worktree-cleanup` sweep. This routine
only reparks.
