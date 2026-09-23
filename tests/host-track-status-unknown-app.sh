#!/usr/bin/env bash
# papercut-host-track-status-unknown-app-jq-noise-20260922
#
# `host-track status <unknown>` prints ONE unknown-app line and exits non-zero
# (no leaked `jq: invalid JSON text passed to --argjson`). An install-root
# alias with a unique match (fkanban -> kanban) resolves to its app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ht="$ROOT/bin/host-track"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ht-unknown-app.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/apps.json" <<'JSON'
{
  "defaults": {"install_mode": "artifact", "artifact_root": "$HOME/.lastgit/artifacts"},
  "apps": [
    {"app": "kanban", "artifact_app": "fkanban", "install_root": "$HOME/.host-track/apps/fkanban", "command": "kanban", "links": []},
    {"app": "lastdb", "artifact_app": "lastdb-bundle", "install_root": "$HOME/.host-track/apps/lastdb-bundle", "command": "lastdb", "links": []},
    {"app": "lastdbd", "artifact_app": "lastdb-bundle", "install_root": "$HOME/.host-track/apps/lastdb-bundle", "command": "lastdbd", "links": []}
  ]
}
JSON
export HOME="$tmp/home" HOST_TRACK_REGISTRY="$tmp/apps.json"
mkdir -p "$HOME"

for sub in "status org" "status org --json" "which org"; do
  rc=0
  # shellcheck disable=SC2086
  "$ht" $sub >"$tmp/out" 2>"$tmp/err" || rc=$?
  [ "$rc" -ne 0 ] || { echo "FAIL: '$sub' must exit non-zero" >&2; exit 1; }
  [ "$(cat "$tmp/err")" = "host-track: unknown app: org" ] || {
    echo "FAIL: '$sub' stderr must be only the unknown-app line, got:" >&2; cat "$tmp/err" >&2; exit 1; }
  [ ! -s "$tmp/out" ] || { echo "FAIL: '$sub' printed stdout:" >&2; cat "$tmp/out" >&2; exit 1; }
done

# Unique install-root / artifact alias resolves.
"$ht" status fkanban --json 2>"$tmp/err" | jq -e '.app == "kanban"' >/dev/null || {
  echo "FAIL: status fkanban must resolve to app kanban" >&2; cat "$tmp/err" >&2; exit 1; }

# An ambiguous alias (two apps share lastdb-bundle) stays unknown.
if "$ht" status lastdb-bundle >/dev/null 2>"$tmp/err"; then
  echo "FAIL: an ambiguous alias must not resolve" >&2; exit 1
fi
[ "$(cat "$tmp/err")" = "host-track: unknown app: lastdb-bundle" ]

echo "ok host-track-status-unknown-app"
