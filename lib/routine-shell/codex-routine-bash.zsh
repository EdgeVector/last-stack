# Codex routine shell entry: run each scheduled Codex command in bash.
# Sourced at the END of ~/.zprofile (setup installs a managed block).
#
# Why (measured 2026-09-23):
#   Codex runs every agent command as `/bin/zsh -lc '<command>'`. It takes the
#   shell from the passwd entry and ignores $SHELL (a codex exec probe with
#   SHELL=/opt/homebrew/bin/bash still ran /bin/zsh -lc). 71 of 76 routines use
#   the Codex harness, and the models write bash. Under zsh that bash fails
#   in known ways: `status` is read-only, `set -- $spec` and `for x in $list`
#   do not word-split, mapfile does not exist, `==` and bare globs error.
#   Wave 1 of the papercut burn-down wrote these rules into a brain SOP; the
#   routines never read it and re-filed ~35 papercuts in 11 hours.
#
# What it does, only for a Codex routine command (DRIVEN_BY=routine from
# routinesd, CODEX_THREAD_ID from Codex, a -c string, not interactive):
#   1. last-stack-routine-shell-lint checks the command. A rejection prints
#      the fix and exits 2 before anything runs.
#   2. exec bash -c "<the same command>". Exit code, stdout and stderr pass
#      through unchanged. PATH and the rest of the env come from ~/.zprofile.
#
# Opt out for one command or one routine: LAST_STACK_ROUTINE_SHELL=zsh.
# Interactive shells, Claude Code shells and Tom's own Codex sessions are
# untouched (no DRIVEN_BY=routine or no CODEX_THREAD_ID).
if [[ ${DRIVEN_BY-} == routine && -n ${CODEX_THREAD_ID-} \
      && -n ${ZSH_EXECUTION_STRING-} && ${LAST_STACK_ROUTINE_SHELL-bash} == bash \
      && ! -o interactive ]]; then
  () {
    local lint="${LAST_STACK_ROUTINE_SHELL_LINT:-$HOME/.last-stack/bin/last-stack-routine-shell-lint}"
    local lint_rc=0 candidate
    if [[ -x $lint ]]; then
      print -r -- "$ZSH_EXECUTION_STRING" | "$lint" --shell bash
      lint_rc=$?
      # Only a real rejection stops the command; a broken lint fails open.
      (( lint_rc == 2 )) && exit 2
    fi
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
      if [[ -x $candidate ]]; then
        exec "$candidate" -c "$ZSH_EXECUTION_STRING"
      fi
    done
    # No bash 4+ on this host: stay in zsh rather than drop to bash 3.2.
  }
fi
