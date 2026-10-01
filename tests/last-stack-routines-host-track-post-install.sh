#!/usr/bin/env bash
# Routines host-track post-install reloads the daemon after current flips.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
hook="$ROOT/bin/last-stack-routines-host-track-post-install"
apps="$ROOT/config/host-track/apps.json"

bash -n "$hook"
chmod +x "$hook"

command -v jq >/dev/null 2>&1 || {
  echo "jq required" >&2
  exit 1
}

jq -e '
  .apps[]
  | select(.app == "routines")
  | .post_install == "$HOME/.local/state/last-stack/artifacts/current/bin/last-stack-routines-host-track-post-install"
    and .safe_upgrade.post_install_phase == "after-cutover"
' "$apps" >/dev/null \
  || {
    echo "FAIL: routines app must run after-cutover install-daemon hook" >&2
    exit 1
  }

jq -e '
  .apps[]
  | select(.app == "last-stack")
  | .links
  | map(.source)
  | index("bin/last-stack-routines-host-track-post-install")
' "$apps" >/dev/null \
  || {
    echo "FAIL: last-stack must PATH-link last-stack-routines-host-track-post-install" >&2
    exit 1
  }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/dist"
mkdir -p "$stub"
launchctl_stub="$tmp/launchctl"
state="$tmp/launchd-loaded"

cat >"$launchctl_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${LAUNCHCTL_STATE:?}"
case "${1:-}" in
  print)
    [ -f "$state" ] || exit 1
    # The real `launchctl print` reports the daemon pid; the drain carve-out
    # reads it as the ancestry boundary.
    [ -z "${LAUNCHCTL_PRINT_PID:-}" ] || {
      echo "	state = running"
      echo "	pid = ${LAUNCHCTL_PRINT_PID}"
    }
    ;;
  kickstart)
    if [ "${LAUNCHCTL_KICKSTART_FAIL:-0}" = "1" ]; then
      echo "Operation not permitted" >&2
      exit 1
    fi
    echo "kickstart" >>"${LAUNCHCTL_CALLS:?}"
    ;;
  *)
    echo "unexpected launchctl call: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$launchctl_stub"

cat >"$stub/routines" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "install-daemon" ]; then
  echo "install-daemon" >>"${ROUTINES_CALLS:?}"
  echo "install-daemon ok"
  exit 0
fi
if [ "${1:-}" = "status" ]; then
  echo "status" >>"${ROUTINES_STATUS_CALLS:-/dev/null}"
  if [ "${ROUTINES_STATUS_FAIL:-0}" = "1" ]; then
    exit 1
  fi
  # Report `running` for the first ROUTINES_STATUS_BUSY_POLLS polls, then idle.
  busy="${ROUTINES_STATUS_BUSY_POLLS:-0}"
  seen=0
  if [ -n "${ROUTINES_STATUS_CALLS:-}" ] && [ -f "$ROUTINES_STATUS_CALLS" ]; then
    seen="$(grep -c . "$ROUTINES_STATUS_CALLS" || true)"
  fi
  if [ -n "${ROUTINES_STATUS_JSON:-}" ]; then
    printf '%s\n' "$ROUTINES_STATUS_JSON"
    exit 0
  fi
  if [ "$busy" -gt 0 ] && [ "$seen" -le "$busy" ]; then
    echo '{"rows":[{"id":"last-stack-fkanban-pickup","running":true}]}'
  else
    echo '{"rows":[{"id":"last-stack-fkanban-pickup","running":false}]}'
  fi
  exit 0
fi
echo "unexpected $*" >&2
exit 2
EOF
chmod +x "$stub/routines"

calls="$tmp/routines-calls"
launchctl_calls="$tmp/launchctl-calls"

# An absent job needs a full install.
out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  ROUTINES_CALLS="$calls" \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook"
)"
printf '%s\n' "$out" | grep -q 'install-daemon ok' \
  || {
    echo "FAIL: expected install-daemon ok: $out" >&2
    exit 1
  }
grep -q 'install-daemon' "$calls" || {
  echo "FAIL: absent job did not call install-daemon" >&2
  exit 1
}

# A loaded job keeps its registration and only restarts the stable launcher.
: >"$calls"
touch "$state"
out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  ROUTINES_CALLS="$calls" \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook"
)"
printf '%s\n' "$out" | grep -q 'kickstart ok' || {
  echo "FAIL: loaded job did not use kickstart: $out" >&2
  exit 1
}
[ ! -s "$calls" ] || {
  echo "FAIL: loaded job must not call install-daemon" >&2
  exit 1
}

status_calls="$tmp/status-calls"

# A loaded job waits for the in-flight count to reach zero before it restarts.
: >"$calls"
: >"$status_calls"
out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  ROUTINES_CALLS="$calls" \
  ROUTINES_STATUS_CALLS="$status_calls" \
  ROUTINES_STATUS_BUSY_POLLS=2 \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  LAST_STACK_ROUTINES_DRAIN_POLL_SEC=1 \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook"
)"
printf '%s\n' "$out" | grep -q 'drained after' || {
  echo "FAIL: a busy fleet must drain before the restart: $out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -q 'kickstart ok' || {
  echo "FAIL: the drain must still restart the daemon: $out" >&2
  exit 1
}
[ "$(grep -c . "$status_calls")" -ge 3 ] || {
  echo "FAIL: the drain polled too few times: $(cat "$status_calls")" >&2
  exit 1
}

# The deadline still restarts, and it names the runs it orphans.
: >"$status_calls"
drain_out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  ROUTINES_CALLS="$calls" \
  ROUTINES_STATUS_CALLS="$status_calls" \
  ROUTINES_STATUS_BUSY_POLLS=999 \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  LAST_STACK_ROUTINES_DRAIN_POLL_SEC=1 \
  LAST_STACK_ROUTINES_DRAIN_MAX_SEC=2 \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook" 2>&1
)"
printf '%s\n' "$drain_out" | grep -q 'drain deadline 2s reached' || {
  echo "FAIL: the deadline must be named: $drain_out" >&2
  exit 1
}
printf '%s\n' "$drain_out" | grep -q 'last-stack-fkanban-pickup' || {
  echo "FAIL: the deadline must name the orphaned runs: $drain_out" >&2
  exit 1
}
printf '%s\n' "$drain_out" | grep -q 'kickstart ok' || {
  echo "FAIL: the deadline must still restart: $drain_out" >&2
  exit 1
}

# An unreadable count is not an empty count; it restarts and says so.
: >"$status_calls"
unknown_out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  ROUTINES_CALLS="$calls" \
  ROUTINES_STATUS_CALLS="$status_calls" \
  ROUTINES_STATUS_FAIL=1 \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook" 2>&1
)"
printf '%s\n' "$unknown_out" | grep -q 'in-flight count unavailable' || {
  echo "FAIL: an unreadable count must warn: $unknown_out" >&2
  exit 1
}
printf '%s\n' "$unknown_out" | grep -q 'kickstart ok' || {
  echo "FAIL: an unreadable count must still restart: $unknown_out" >&2
  exit 1
}

# LAST_STACK_ROUTINES_DRAIN_MAX_SEC=0 keeps the emergency immediate reload.
: >"$status_calls"
now_out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  ROUTINES_CALLS="$calls" \
  ROUTINES_STATUS_CALLS="$status_calls" \
  ROUTINES_STATUS_BUSY_POLLS=999 \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  LAST_STACK_ROUTINES_DRAIN_MAX_SEC=0 \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook"
)"
printf '%s\n' "$now_out" | grep -q 'kickstart ok' || {
  echo "FAIL: drain 0 must restart at once: $now_out" >&2
  exit 1
}
[ ! -s "$status_calls" ] || {
  echo "FAIL: drain 0 must not read status: $(cat "$status_calls")" >&2
  exit 1
}

# The run performing the drain is carved out of the drain set. Its own row is
# `running:true` until it exits, and it cannot exit while it waits here, so
# counting it makes the wait unsatisfiable: the whole deadline burns and the
# restart orphans the caller
# (papercut-host-track-refresh-routines-self-deadlock-kills-own-caller-20261001).
# `$$` here is this test script, a real ancestor of the hook, standing in for the
# calling run's harness; the boundary sits one level above it.
: >"$status_calls"
self_out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  LAUNCHCTL_PRINT_PID="$PPID" \
  ROUTINES_CALLS="$calls" \
  ROUTINES_STATUS_CALLS="$status_calls" \
  ROUTINES_STATUS_JSON="{\"rows\":[{\"id\":\"last-stack-papercut-resolver\",\"running\":true,\"harnessPid\":$$}]}" \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  LAST_STACK_ROUTINES_DRAIN_POLL_SEC=1 \
  LAST_STACK_ROUTINES_DRAIN_MAX_SEC=2 \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook" 2>&1
)"
printf '%s\n' "$self_out" | grep -q 'carving this run out of the drain' || {
  echo "FAIL: the caller's own run must be carved out: $self_out" >&2
  exit 1
}
printf '%s\n' "$self_out" | grep -q 'drain deadline' && {
  echo "FAIL: carving out the caller must not burn the deadline: $self_out" >&2
  exit 1
}
printf '%s\n' "$self_out" | grep -q 'kickstart ok' || {
  echo "FAIL: a carved-out caller must still restart: $self_out" >&2
  exit 1
}

# The boundary is load-bearing. One running row was measured reporting
# routinesd's OWN pid as its harnessPid, and every dispatch descends from
# routinesd -- so an ancestry match that did not stop at the daemon would carve
# out an unrelated run and re-open the 2026-09-06 orphan bug. A row at the
# daemon pid must still be drained and still be named.
: >"$status_calls"
daemon_out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  LAUNCHCTL_PRINT_PID="$PPID" \
  ROUTINES_CALLS="$calls" \
  ROUTINES_STATUS_CALLS="$status_calls" \
  ROUTINES_STATUS_JSON="{\"rows\":[{\"id\":\"last-stack-whats-wrong\",\"running\":true,\"harnessPid\":$PPID}]}" \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  LAST_STACK_ROUTINES_DRAIN_POLL_SEC=1 \
  LAST_STACK_ROUTINES_DRAIN_MAX_SEC=2 \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook" 2>&1
)"
printf '%s\n' "$daemon_out" | grep -q 'drain deadline 2s reached' || {
  echo "FAIL: a row at the daemon pid must still be drained: $daemon_out" >&2
  exit 1
}
printf '%s\n' "$daemon_out" | grep -q 'last-stack-whats-wrong' || {
  echo "FAIL: a row at the daemon pid must still be named as orphaned: $daemon_out" >&2
  exit 1
}

# An unrelated concurrent run is not an ancestor, so it is still drained. The
# carve-out is one run, not a blanket exemption.
: >"$status_calls"
other_out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  LAUNCHCTL_PRINT_PID="$PPID" \
  ROUTINES_CALLS="$calls" \
  ROUTINES_STATUS_CALLS="$status_calls" \
  ROUTINES_STATUS_JSON="{\"rows\":[{\"id\":\"last-stack-papercut-resolver\",\"running\":true,\"harnessPid\":$$},{\"id\":\"last-stack-fkanban-pickup\",\"running\":true,\"harnessPid\":1}]}" \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  LAST_STACK_ROUTINES_DRAIN_POLL_SEC=1 \
  LAST_STACK_ROUTINES_DRAIN_MAX_SEC=2 \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook" 2>&1
)"
printf '%s\n' "$other_out" | grep -q 'last-stack-fkanban-pickup' || {
  echo "FAIL: an unrelated run must still be drained: $other_out" >&2
  exit 1
}
printf '%s\n' "$other_out" | grep -q 'orphans: last-stack-papercut-resolver' && {
  echo "FAIL: the carved-out caller must not be named as orphaned: $other_out" >&2
  exit 1
}

# No daemon pid means no boundary, so the carve-out is skipped entirely and the
# drain behaves exactly as it did before the carve-out existed. This property is
# protected twice -- the unreadable-pid arm returns early, and a walk that never
# reaches the daemon also yields nothing -- so no single-point mutation turns
# this case red; removing both protections does.
: >"$status_calls"
noboundary_out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  ROUTINES_CALLS="$calls" \
  ROUTINES_STATUS_CALLS="$status_calls" \
  ROUTINES_STATUS_JSON="{\"rows\":[{\"id\":\"last-stack-papercut-resolver\",\"running\":true,\"harnessPid\":$$}]}" \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  LAST_STACK_ROUTINES_DRAIN_POLL_SEC=1 \
  LAST_STACK_ROUTINES_DRAIN_MAX_SEC=2 \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook" 2>&1
)"
printf '%s\n' "$noboundary_out" | grep -q 'carving this run out' && {
  echo "FAIL: no daemon pid must mean no carve-out: $noboundary_out" >&2
  exit 1
}
printf '%s\n' "$noboundary_out" | grep -q 'drain deadline 2s reached' || {
  echo "FAIL: no carve-out must keep the old drain behaviour: $noboundary_out" >&2
  exit 1
}

cat >"$stub/routines" <<'EOF'
#!/usr/bin/env bash
echo "Operation not permitted" >&2
exit 1
EOF
chmod +x "$stub/routines"

# A refused kickstart does not unregister the loaded job.
set +e
perm_out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  LAUNCHCTL_KICKSTART_FAIL=1 \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook" 2>&1
)"
perm_rc=$?
set -e
[ "$perm_rc" -eq 0 ] || {
  echo "FAIL: loaded job must survive a refused kickstart: $perm_out" >&2
  exit 1
}
printf '%s\n' "$perm_out" | grep -qi 'WARN' \
  || {
    echo "FAIL: expected permission WARN: $perm_out" >&2
    exit 1
  }

# An absent job plus a refused install is a failed activation.
rm -f "$state"
set +e
perm_out="$(
  LAUNCHCTL_STATE="$state" \
  LAUNCHCTL_CALLS="$launchctl_calls" \
  LAST_STACK_LAUNCHCTL_BIN="$launchctl_stub" \
  HOST_TRACK_VERSION_DIR="$tmp" \
  "$hook" 2>&1
)"
perm_rc=$?
set -e
[ "$perm_rc" -ne 0 ] || {
  echo "FAIL: absent job must fail when install-daemon is refused: $perm_out" >&2
  exit 1
}
printf '%s\n' "$perm_out" | grep -q 'install-daemon failed' || {
  echo "FAIL: absent job failure needs install detail: $perm_out" >&2
  exit 1
}

echo "ok last-stack-routines-host-track-post-install"
