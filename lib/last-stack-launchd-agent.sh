#!/usr/bin/env bash
# Shared LaunchAgent install helpers.
#
# Version-hashed artifact trees (`artifacts/versions/<sha>/`) must never be
# written into a live plist: last-stack setup invokes installers from that
# physical path, and `pwd -P` plus bootout/bootstrap makes macOS treat each
# refresh as a new background item (App Background Activity toast).
#
# Public roots stay stable across promotions:
#   $HOME/.last-stack
#   $HOME/.local/state/last-stack/artifacts/current
#
# Environment:
#   LAST_STACK_PUBLIC_ROOT     — force the path written into the plist
#   LAST_STACK_LAUNCHD_DOMAIN  — "none"/"skip"/"off" writes the plist only
#                                and never calls launchctl

last_stack_agent_logical_root() {
  cd "$(dirname "$1")/.." && pwd
}

last_stack_agent_physical_root() {
  cd "$(dirname "$1")/.." && pwd -P
}

# $1 = installer $0, $2 = program basename that must exist under bin/
last_stack_agent_stable_root() {
  local installer="$1" program="$2" phys current
  if [ -n "${LAST_STACK_PUBLIC_ROOT:-}" ]; then
    printf '%s\n' "$LAST_STACK_PUBLIC_ROOT"
    return 0
  fi
  if [ -e "$HOME/.last-stack/bin/$program" ]; then
    printf '%s\n' "$HOME/.last-stack"
    return 0
  fi
  if [ -e "$HOME/.local/state/last-stack/artifacts/current/bin/$program" ]; then
    printf '%s\n' "$HOME/.local/state/last-stack/artifacts/current"
    return 0
  fi
  phys="$(last_stack_agent_physical_root "$installer")"
  case "$phys" in
    */artifacts/versions/*)
      current="${phys%/versions/*}/current"
      if [ -e "$current/bin/$program" ]; then
        printf '%s\n' "$current"
        return 0
      fi
      ;;
  esac
  last_stack_agent_logical_root "$installer"
}

last_stack_agent_uid_home() {
  local name home
  name="$(id -un)"
  home="$(dscl . -read "/Users/${name}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  if [ -n "${home:-}" ]; then
    printf '%s\n' "$home"
    return 0
  fi
  eval echo "~${name}"
}

# $1 = destination plist path
last_stack_agent_should_touch_launchd() {
  local dest="$1" real_home
  case "${LAST_STACK_LAUNCHD_DOMAIN:-}" in
    none|skip|off) return 1 ;;
  esac
  real_home="$(last_stack_agent_uid_home)"
  case "$dest" in
    "$real_home"/Library/LaunchAgents/*) return 0 ;;
  esac
  return 1
}

# Render a launchd template: swap /Users/REPLACE* to HOME + stable root,
# and the leftover USER value "REPLACE".
# $1 = src template, $2 = dest, $3 = stable last_stack root
last_stack_agent_render_plist() {
  local src="$1" dest="$2" last_stack="$3" user
  user="${USER:-$(id -un)}"
  mkdir -p "$(dirname "$dest")"
  sed \
    -e "s|/Users/REPLACE/.last-stack|${last_stack}|g" \
    -e "s|/Users/REPLACE|${HOME}|g" \
    -e "s|<string>REPLACE</string>|<string>${user}</string>|g" \
    "$src" >"$dest"
}

# Write dest only when contents change. Load launchd only when dest is under
# the uid's real home and LAST_STACK_LAUNCHD_DOMAIN is not none/skip/off.
# $1 = label, $2 = dest plist, $3 = rendered temp plist, $4 = human name
last_stack_agent_commit_plist() {
  local label="$1" dest="$2" rendered="$3" name="$4"
  local uid domain
  uid="$(id -u)"
  domain="${LAST_STACK_LAUNCHD_DOMAIN:-gui/${uid}}"

  if [ -f "$dest" ] && cmp -s "$rendered" "$dest"; then
    rm -f "$rendered"
    echo "${name}: already current, skipped launchctl"
    return 0
  fi
  mv -f "$rendered" "$dest"

  if ! last_stack_agent_should_touch_launchd "$dest"; then
    echo "${name}: plist written $dest (launchctl skipped)"
    return 0
  fi

  if ! command -v launchctl >/dev/null 2>&1; then
    echo "${name}: plist written $dest (no launchctl)"
    return 0
  fi

  launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
  if launchctl bootstrap "$domain" "$dest" >/dev/null 2>&1; then
    launchctl enable "${domain}/${label}" >/dev/null 2>&1 || true
    launchctl kickstart -k "${domain}/${label}" >/dev/null 2>&1 || true
    echo "${name}: loaded ${label}"
  else
    echo "${name}: plist at $dest (bootstrap failed)" >&2
  fi
}

last_stack_agent_uninstall() {
  local label="$1" dest="$2" name="$3"
  local uid domain
  uid="$(id -u)"
  domain="${LAST_STACK_LAUNCHD_DOMAIN:-gui/${uid}}"
  if last_stack_agent_should_touch_launchd "$dest"; then
    launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
  fi
  rm -f "$dest"
  echo "${name}: uninstalled"
}
