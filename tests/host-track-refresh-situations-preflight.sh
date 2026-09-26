#!/usr/bin/env bash
# papercut-loom-held-build-promoted-and-installed-during-situation-hold-20260926
#
# `host-track refresh <app>` asks Situations before it stages anything. On
# 2026-09-25 loom-budget-schema-deployment-hold-20260925 went active with
# host-track-refresh in blocked_actions and EdgeVector/loom in scope, and
# host-track installed loom three times under it. Nothing on the refresh path
# had ever read the policy.
#
# The fake `situations` here is the whole point: the decision table has four
# outcomes (allow / blocked / unreadable / no policy store) and only a stub can
# produce all four on demand.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ht="$ROOT/bin/host-track"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ht-refresh-preflight.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/home" "$tmp/stub"
cat >"$tmp/apps.json" <<'JSON'
{
  "defaults": {"install_mode": "artifact", "artifact_root": "$HOME/.lastgit/artifacts"},
  "apps": [
    {"app": "loom", "artifact_app": "loom", "gate_main": "http://localhost:3300/EdgeVector/loom.git#main",
     "install_root": "$HOME/.host-track/apps/loom", "command": "loom", "links": []},
    {"app": "kanban", "artifact_app": "fkanban", "gate_main": "http://localhost:3300/EdgeVector/fkanban.git#main",
     "install_root": "$HOME/.host-track/apps/fkanban", "command": "kanban", "links": []},
    {"app": "situations", "artifact_app": "situations", "gate_main": "http://localhost:3300/EdgeVector/situations.git#main",
     "install_root": "$HOME/.host-track/apps/situations", "command": "situations", "links": []},
    {"app": "nogate", "artifact_app": "nogate",
     "install_root": "$HOME/.host-track/apps/nogate", "command": "nogate", "links": []}
  ]
}
JSON

# A `situations` stub whose exit code and recorded argv the test controls.
cat >"$tmp/stub/situations" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SITUATIONS_CALLS"
case "${SITUATIONS_RC:-0}" in
  3) printf 'loom-budget-schema-deployment-hold-20260925\tblocked\n'; exit 3 ;;
  0) exit 0 ;;
  *) printf 'node did not respond within 30000ms\n' >&2; exit "${SITUATIONS_RC}" ;;
esac
STUB
chmod +x "$tmp/stub/situations"

export HOME="$tmp/home" HOST_TRACK_REGISTRY="$tmp/apps.json"
export SITUATIONS_CALLS="$tmp/calls"
export HOST_TRACK_SITUATIONS_BIN="$tmp/stub/situations"
export HOST_TRACK_SKIP_SOAK_WATCH=1

run_refresh() {
  local app="$1" rc=0
  : >"$SITUATIONS_CALLS"
  "$ht" refresh "$app" >"$tmp/out" 2>"$tmp/err" || rc=$?
  printf '%s' "$rc"
}

# 1. BLOCKED refuses, with exit 3 and the Situation named.
export SITUATIONS_RC=3
rc="$(run_refresh loom)"
[ "$rc" = "3" ] || { echo "FAIL: a blocked refresh must exit 3, got $rc" >&2; cat "$tmp/err" >&2; exit 1; }
grep -q "REFUSED: Situations blocks host-track-refresh on EdgeVector/loom" "$tmp/err" || {
  echo "FAIL: the refusal must name the action and the repo:" >&2; cat "$tmp/err" >&2; exit 1; }
grep -q "loom-budget-schema-deployment-hold-20260925" "$tmp/err" || {
  echo "FAIL: the refusal must name the blocking Situation:" >&2; cat "$tmp/err" >&2; exit 1; }

# 2. The repo comes from the REGISTRY, not from the app name. kanban is
#    EdgeVector/fkanban; asking about EdgeVector/kanban would get an
#    unconditional OK from a policy store that has no such repo.
export SITUATIONS_RC=3
run_refresh kanban >/dev/null
grep -q -- "--repo EdgeVector/fkanban" "$SITUATIONS_CALLS" || {
  echo "FAIL: kanban must be asked about EdgeVector/fkanban, got:" >&2; cat "$SITUATIONS_CALLS" >&2; exit 1; }
grep -q -- "--action host-track-refresh" "$SITUATIONS_CALLS" || {
  echo "FAIL: the guard must ask about host-track-refresh:" >&2; cat "$SITUATIONS_CALLS" >&2; exit 1; }

# 3. A preflight that RAN and failed refuses too: unattended timer, nobody
#    reading stderr, and the next tick retries.
export SITUATIONS_RC=1
rc="$(run_refresh loom)"
[ "$rc" = "3" ] || { echo "FAIL: an unreadable policy must refuse, got $rc" >&2; cat "$tmp/err" >&2; exit 1; }
grep -q "could not be read" "$tmp/err" || {
  echo "FAIL: an unreadable policy must say so, not claim a block:" >&2; cat "$tmp/err" >&2; exit 1; }

# 4. The bootstrap set proceeds on UNREADABLE -- needing a working policy store
#    to install the fix for a broken policy store is a deadlock.
export SITUATIONS_RC=1
rc="$(run_refresh situations)"
[ "$rc" != "3" ] || {
  echo "FAIL: situations must not be refused on an unreadable policy:" >&2; cat "$tmp/err" >&2; exit 1; }
grep -q "bootstrap set" "$tmp/err" || {
  echo "FAIL: the bootstrap bypass must say it happened:" >&2; cat "$tmp/err" >&2; exit 1; }

# 4b. ...but an EXPLICIT block still refuses, bootstrap or not.
export SITUATIONS_RC=3
rc="$(run_refresh situations)"
[ "$rc" = "3" ] || {
  echo "FAIL: an explicit block must refuse even in the bootstrap set, got $rc" >&2; cat "$tmp/err" >&2; exit 1; }

# 5. OK lets the refresh through. These fixture apps then fail for an unrelated
#    reason (a throwaway $HOME has no artifact store), which is exactly why the
#    assertion is "not refused by the guard" rather than "succeeded".
export SITUATIONS_RC=0
run_refresh loom >/dev/null
grep -q "REFUSED" "$tmp/err" && { echo "FAIL: an OK preflight must not refuse:" >&2; cat "$tmp/err" >&2; exit 1; }
[ -s "$SITUATIONS_CALLS" ] || { echo "FAIL: the guard did not call situations at all" >&2; exit 1; }

# 6. A host with no policy store proceeds, and does not call anything.
export SITUATIONS_RC=3
(
  unset HOST_TRACK_SITUATIONS_BIN
  export PATH="/usr/bin:/bin"
  : >"$SITUATIONS_CALLS"
  rc=0
  "$ht" refresh loom >"$tmp/out" 2>"$tmp/err" || rc=$?
  [ "$rc" != "3" ] || { echo "FAIL: a host with no situations binary must not be refused" >&2; cat "$tmp/err" >&2; exit 1; }
  [ ! -s "$SITUATIONS_CALLS" ] || { echo "FAIL: nothing should have been called" >&2; exit 1; }
)

# 7. An app whose registry entry has no gate_main is unaskable, says so, and is
#    not silently refused out of the sweep.
export SITUATIONS_RC=3
rc="$(run_refresh nogate)"
[ "$rc" != "3" ] || { echo "FAIL: an app with no gate_main must not be refused" >&2; cat "$tmp/err" >&2; exit 1; }
grep -q "no readable gate_main repo" "$tmp/err" || {
  echo "FAIL: an unaskable app must say why:" >&2; cat "$tmp/err" >&2; exit 1; }
[ ! -s "$SITUATIONS_CALLS" ] || { echo "FAIL: nothing should have been called for nogate" >&2; exit 1; }

# 8. `refresh --all` must SKIP a blocked app and KEEP GOING. Exit 3 is the code
#    the --all loop already treats as not-a-failure (deployment-only uses it),
#    so the proof is that every app after the first blocked one was still
#    visited -- not the sweep's exit code, which these fixture apps fail for
#    unrelated reasons (no artifact store under a throwaway $HOME).
export SITUATIONS_RC=3
"$ht" refresh --all >"$tmp/out" 2>"$tmp/err" || true
grep -q "loom REFUSED" "$tmp/err" || {
  echo "FAIL: --all must refuse the blocked app:" >&2; cat "$tmp/err" >&2; exit 1; }
grep -q "kanban REFUSED" "$tmp/err" || {
  echo "FAIL: --all must reach the app after the first refusal:" >&2; cat "$tmp/err" >&2; exit 1; }
grep -q "nogate has no readable gate_main repo" "$tmp/err" || {
  echo "FAIL: --all must reach the LAST app after two refusals:" >&2; cat "$tmp/err" >&2; exit 1; }

echo "ok host-track-refresh-situations-preflight"
