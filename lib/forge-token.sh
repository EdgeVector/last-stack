#!/usr/bin/env bash
# Resolve the Forgejo API/push token for the local forge.
#
# The login keychain is not a dependency an unattended agent can rely on. When
# it locks, `security find-generic-password` exits 51 (errSecInteractionNotAllowed)
# or 25293 (errSecAuthFailed) and prints NOTHING to stderr, so every forge path
# — API, push, PR create, portal fetch — fails at once with no way to tell a
# locked keychain from a missing item. That took the whole Forgejo venue offline
# for unattended work five times on 2026-09-06 (03:55, 04:06, 04:08, 04:20,
# 04:49Z) across five different routines, on the day Forgejo became the gate of
# record for last-stack, fkanban, routines and loom.
#
# Resolution order, first non-empty wins:
#   1. $FORGE_TOKEN                     — explicit override
#   2. keychain item `forgejo-token`    — the interactive default
#   3. lastsecrets://forgejo-token      — survives a locked keychain
#
# lastsecrets is last so an operator's keychain rotation still wins locally, and
# so this adds a node read only on the path that was already failing.
#
# Papercut: papercut-forge-helpers-keychain-lockout-blocks-unattended-push

# Prints the token on stdout, or nothing. Never prints the token to stderr.
last_stack_forge_token() {
  local token="${FORGE_TOKEN:-}"
  if [ -n "$token" ]; then
    printf '%s' "$token"
    return 0
  fi

  token="$(security find-generic-password -s forgejo-token -w 2>/dev/null || true)"
  if [ -n "$token" ]; then
    printf '%s' "$token"
    return 0
  fi

  if command -v lastsecrets >/dev/null 2>&1; then
    # `lastsecrets get` prints the bare value on stdout and diagnostics on
    # stderr; a missing secret exits non-zero with an empty stdout.
    token="$(lastsecrets get forgejo-token 2>/dev/null || true)"
    token="${token%%$'\n'*}"
    if [ -n "$token" ]; then
      printf '%s' "$token"
      return 0
    fi
  fi

  return 1
}

# The one message every forge helper prints when no source had a token. Names
# all three sources, so a reader is not sent to the keychain when the keychain
# is exactly what is broken.
last_stack_forge_token_missing_msg() {
  cat >&2 <<'MSG'
missing Forgejo token. Tried, in order:
  1. $FORGE_TOKEN                     (unset or empty)
  2. keychain item `forgejo-token`    (absent, or the login keychain is locked
     to non-interactive readers — `security ... -w` exits 51/25293 silently)
  3. lastsecrets://forgejo-token      (not found)
Store the fallback so a locked keychain cannot block unattended work:
  forgejo --config /opt/homebrew/var/forgejo/custom/conf/app.ini \
    admin user generate-access-token --username <user> \
    --scopes write:repository,write:issue --raw --token-name <name> \
  | lastsecrets put forgejo-token --label 'Forgejo API + push token' \
      --provider forgejo --purpose 'unattended forge push/PR' --env local \
      --value-stdin
MSG
}

# --- keeping the token off process argv -------------------------------------
#
# `ps aux` is readable by every local account. A token passed as
# `git -c http.<base>.extraHeader=Authorization: token <t>` or as
# `curl -H "Authorization: token <t>"` is therefore a secret published to the
# whole machine for the life of the process. Both were observed live:
#   papercut-forge-git-extraheader-token-visible-in-ps-20260923   (p0, git)
#   papercut-last-stack-forge-api-token-on-curl-argv-20260924     (p1, curl)
#
# Measured on this host (Darwin 25.5, 2026-09-25): `ps -E -ww -p <pid>` and
# `ps eww -p <pid>` print NO environment, not even for the caller's own child,
# while `ps aux` prints the full argv. So the environment is a real boundary
# here and argv is not. A curl config file adds the stronger form: the bytes sit
# in a 0600 file that only this uid can open.
#
# Use these two helpers instead of hand-building an auth word list.

# Export the forge token as git HTTP config in the ENVIRONMENT, for both spellings
# of the local forge host. Appends to any GIT_CONFIG_COUNT a caller already set
# (last-stack-portal-wt exports two entries of its own), so nesting one forge
# helper inside another does not silently drop the outer config.
# Returns 1 with nothing exported when no token source has a token.
last_stack_forge_export_git_config() {
  local token base count
  token="$(last_stack_forge_token || true)"
  [ -n "$token" ] || return 1
  count="${GIT_CONFIG_COUNT:-0}"
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  for base in "http://localhost:3300/" "http://127.0.0.1:3300/"; do
    export "GIT_CONFIG_KEY_$count=http.${base}.extraHeader"
    export "GIT_CONFIG_VALUE_$count=Authorization: token $token"
    count=$((count + 1))
  done
  export GIT_CONFIG_COUNT="$count"
}

# Write a curl config file (`curl -K <file>`) holding the Authorization header and
# print its path. The file is created 0600 inside a private directory; the caller
# owns removing it, normally from the same trap that cleans its body file.
# Returns 1 and prints nothing when no token source has a token.
last_stack_forge_curl_auth_config() {
  local token dir file old_umask
  token="$(last_stack_forge_token || true)"
  [ -n "$token" ] || return 1
  old_umask="$(umask)"
  umask 077
  dir="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-forge-auth.XXXXXX")" || { umask "$old_umask"; return 1; }
  file="$dir/auth.conf"
  # curl reads long option names without dashes from a config file. A quoted
  # value keeps the space in "token <t>" intact.
  printf 'header = "Authorization: token %s"\n' "$token" >"$file"
  umask "$old_umask"
  chmod 600 "$file" 2>/dev/null || true
  printf '%s' "$file"
}
