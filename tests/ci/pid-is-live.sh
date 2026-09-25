# shellcheck shell=bash
# pid_is_live PID: true while PID exists and is not a zombie.
#
# `kill -0` also succeeds on a zombie. In the gaming PC CI container the init
# process may keep a killed orphan as a zombie, so a check for "the driver
# stopped its child" must not count one: a zombie does not run.
pid_is_live() {
  local pid="$1" state=""
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/stat" ]; then
    # Field 3 follows the ")" that closes the command name.
    state="$(sed -n 's/^.*) \([A-Za-z]\).*$/\1/p' "/proc/$pid/stat" 2>/dev/null || true)"
  else
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  case "$state" in Z*) return 1 ;; esac
  return 0
}
