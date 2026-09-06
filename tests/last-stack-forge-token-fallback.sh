#!/usr/bin/env bash
# The forge token must survive a locked login keychain.
#
# On 2026-09-06 the login keychain locked to non-interactive readers.
# `security find-generic-password -s forgejo-token -w` exited 51 and printed
# NOTHING, so last-stack-forge-api, last-stack-forge-git and
# last-stack-portal-wt all failed at once and no unattended agent could push,
# open a PR, or even fetch a portal tip — on the day Forgejo became the gate of
# record for last-stack, fkanban, routines and loom. Five routines hit it in
# one night.
#
# Papercut: papercut-forge-helpers-keychain-lockout-blocks-unattended-push
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$tmp/stub"
PATH="$tmp/stub:$PATH"
export PATH

# `security` stands in for the keychain. KEYCHAIN_VALUE empty => locked: exit
# 51 with an empty stderr, exactly as the real lockout behaves.
cat > "$tmp/stub/security" <<'STUB'
#!/usr/bin/env bash
if [ -n "${KEYCHAIN_VALUE:-}" ]; then
  printf '%s\n' "$KEYCHAIN_VALUE"
  exit 0
fi
exit 51
STUB
cat > "$tmp/stub/lastsecrets" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = forgejo-token ] && [ -n "${LASTSECRETS_VALUE:-}" ]; then
  printf '%s\n' "$LASTSECRETS_VALUE"
  exit 0
fi
echo "lastsecrets: secret not found: ${2:-}" >&2
exit 1
STUB
chmod +x "$tmp/stub/security" "$tmp/stub/lastsecrets"

# shellcheck source=../lib/forge-token.sh
. "$ROOT/lib/forge-token.sh"

# --- 1. $FORGE_TOKEN wins ---------------------------------------------------
got="$(FORGE_TOKEN=from-env KEYCHAIN_VALUE=from-keychain \
  LASTSECRETS_VALUE=from-lastsecrets last_stack_forge_token || true)"
[ "$got" = "from-env" ] || fail "FORGE_TOKEN must win, got '$got'"

# --- 2. keychain outranks lastsecrets ---------------------------------------
# An operator rotating the keychain locally must not be overridden by a stale
# stored fallback.
got="$(KEYCHAIN_VALUE=from-keychain LASTSECRETS_VALUE=from-lastsecrets \
  last_stack_forge_token || true)"
[ "$got" = "from-keychain" ] || fail "keychain must outrank lastsecrets, got '$got'"

# --- 3. THE REGRESSION: locked keychain falls back to lastsecrets -----------
got="$(KEYCHAIN_VALUE= LASTSECRETS_VALUE=from-lastsecrets last_stack_forge_token || true)"
[ "$got" = "from-lastsecrets" ] \
  || fail "a locked keychain (rc 51) must fall back to lastsecrets, got '$got'"

# --- 4. no source at all: non-zero, and the message names all three ---------
if got="$(KEYCHAIN_VALUE= LASTSECRETS_VALUE= last_stack_forge_token)"; then
  fail "no source must return non-zero, got '$got'"
fi
msg="$(last_stack_forge_token_missing_msg 2>&1)"
for needle in 'FORGE_TOKEN' 'keychain' 'lastsecrets'; do
  printf '%s\n' "$msg" | grep -q "$needle" \
    || fail "missing-token message must name $needle, got: $msg"
done
# The message must not send a reader to the keychain without saying the
# keychain is the thing that breaks.
printf '%s\n' "$msg" | grep -q 'locked' \
  || fail "missing-token message must name the locked-keychain case"

# --- 5. NO helper keeps its own copy of the keychain read -------------------
# This used to enumerate two files while its own comment promised the class.
# Four helpers were outside that list, and the guard stayed green while
# `last-stack-forge-ci-log` exited 3 on every unattended pass for six hours —
# the one instrument five open p0 pipeline papercuts were waiting on to name
# why routines#10, loom#9/#11/#12, fold#1954/#1955 and last-stack#20/#21 were
# red. A list is not a class: scan every executable instead.
#
# lib/forge-token.sh is the ONE place allowed to name the keychain item.
# Sole exemption: last-stack-forge-runner-lanes is python and cannot source a
# bash lib, so it reimplements the same three-step order. The check below
# asserts it kept the lastsecrets step.
offenders="$(grep -rln 'find-generic-password[^\n]*forgejo-token' "$ROOT/bin" \
  | grep -v '/last-stack-forge-runner-lanes$' || true)"
[ -z "$offenders" ] || fail "these must resolve the token through lib/forge-token.sh, not read the keychain directly:
$offenders"

# And every helper that talks to the forge must actually call the resolver.
# `forgejo-admin` (the WEB password) is deliberately not in scope: it has no
# stored fallback, which is why last-stack-forge-ci-log reads the job log off
# disk and only reaches for a web session when that file is absent.
for h in bin/last-stack-forge-api bin/last-stack-forge-git bin/last-stack-forge-ci-log \
         bin/last-stack-git-checkout-freshness bin/last-stack-dogfood-target-checkout \
         bin/last-stack-portal-wt; do
  grep -q 'last_stack_forge_token' "$ROOT/$h" \
    || fail "$h must resolve its token through last_stack_forge_token"
done
# The python helper cannot source the bash lib, so it needs its own fallback.
# Match the argv, not the word: the first version of this check passed on a
# docstring that merely mentioned lastsecrets while the call site was gone.
grep -q '"lastsecrets", "get", "forgejo-token"' "$ROOT/bin/last-stack-forge-runner-lanes" \
  || fail "last-stack-forge-runner-lanes must fall back to lastsecrets when the keychain is locked"

# --- 6. the ci-log helper must not need a credential for an on-disk log -----
grep -q 'FORGE_ACTIONS_LOG_ROOT' "$ROOT/bin/last-stack-forge-ci-log" \
  || fail "last-stack-forge-ci-log must read the job log from the forge actions_log root"
# The web login must be lazy. A top-level `exit 3` on a missing web password
# is what made a locked keychain fatal even when the log was sitting on disk.
awk '/^web_login\(\)/,/^}/' "$ROOT/bin/last-stack-forge-ci-log" | grep -q 'return 3' \
  || fail "last-stack-forge-ci-log must defer the web-password requirement into web_login()"
# Forgejo does not keep a log for every task (loom run 35's GREEN `ci-required`
# has no file while the `skipped` job in the same run does), so one unreadable
# job must not sink the jobs that did read.
grep -q 'NO LOG AVAILABLE' "$ROOT/bin/last-stack-forge-ci-log" \
  || fail "last-stack-forge-ci-log must report a per-job missing log and continue"
awk '/^for idx in \$targets/,0' "$ROOT/bin/last-stack-forge-ci-log" | grep -q 'read_ok=$(( read_ok + 1 ))' \
  || fail "last-stack-forge-ci-log must count the jobs it actually read"

printf 'ok: forge token fallback (env > keychain > lastsecrets, locked keychain, no helper reads the keychain directly, ci-log reads on-disk logs)\n'
