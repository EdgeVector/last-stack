# Portal agent rules

1. This is a **portal**, not the product repo.
2. Before any product edit: `./bin/wt start kanban/<slug>` and `cd` to the path it prints.
3. Never commit in the portal directory.
4. Prefer `./bin/wt fetch` if you only need the latest tip for inspection via a throwaway worktree.
5. **File a papercut for every piece of friction you hit** — a tool that
   misbehaves, a confusing error, a stale doc, a manual workaround, a check that
   reports about something it cannot observe. The default is FILE, not judge:
   the gate is "is this a distinct claim someone would want to find?", not
   "is it big enough". File to the **brain**, never straight to the board — one
   reconciler routine owns turning papercuts into cards. Search first and read
   what you find as a remedy, not just as precedent.
6. **A mention is not a filing.** Prose in a commit message, a PR description, a
   run summary, or a closure block produces no card. If it has no slug of its
   own, it was not filed — and an aside buried in a record you then CLOSE is
   worse than not filing at all, because it reads as recorded while being
   invisible to every open-backlog reader. Before closing a record, check
   whether its body makes a claim about anything other than what you are
   closing.
