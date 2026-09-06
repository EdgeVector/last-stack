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
