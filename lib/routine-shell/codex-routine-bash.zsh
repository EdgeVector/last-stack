# Codex routine shell entry: run each scheduled Codex command in bash.
# Sourced at the END of ~/.zshenv (setup installs a managed block).
#
# Why (measured 2026-09-23):
#   Codex runs every agent command in zsh (its log shows `/bin/zsh -lc`, but
#   the live shell has no login flag, so ~/.zprofile is NOT read; ~/.zshenv
#   is read by every zsh). Codex takes the
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
#      through unchanged. PATH and the rest of the env are inherited.
#
# Opt out for one command or one routine: LAST_STACK_ROUTINE_SHELL=zsh.
# Interactive shells, zsh scripts (no -c string), Claude Code shells
# (CLAUDECODE set) and Tom's own Codex sessions (no DRIVEN_BY=routine) are
# untouched.
if [[ ${DRIVEN_BY-} == routine && -n ${CODEX_THREAD_ID-} && -z ${CLAUDECODE-} \
      && -n ${ZSH_EXECUTION_STRING-} && ${LAST_STACK_ROUTINE_SHELL-bash} == bash \
      && ! -o interactive ]]; then
  () {
    # Codex wraps the agent command: the outer zsh runs
    #   exec '/bin/zsh' -c '<command>'
    # Let that exec happen; the inner zsh reads this file again and sees the
    # raw command, so the lint reads the real text once (not the re-quoted
    # wrapper, where heredoc quotes look like '"'"'EOF'"'"').
    case $ZSH_EXECUTION_STRING in
      ("exec '/bin/zsh' -c "*|"exec /bin/zsh -c "*) return 0 ;;
    esac
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
