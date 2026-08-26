#!/usr/bin/env bash
# COLLECT: read the app's live soak state and classify it for DECIDE.
# verdict: green | soaking | red | exhausted.
# Reads the incident from the host-track soak stamp; the attempt count lives
# in loom context (patched by FIX) so it survives digest changes — the ×3
# budget is per INCIDENT, never per digest.
set -euo pipefail

input="${LOOM_INPUT:-"{}"}"
app="$(printf '%s' "$input" | jq -r '.app // empty')"
[ -n "$app" ] || { echo "collect: app missing from input" >&2; exit 1; }
max_attempts="$(printf '%s' "$input" | jq -r '.max_attempts // 3')"
attempt="$(printf '%s' "$input" | jq -r '.attempt // 0')"

stamp_dir="${HOST_TRACK_STAMP_DIR:-$HOME/.host-track/stamps}"
stamp="$stamp_dir/$app.soak.json"

verdict=""
digest=""
probe_tail=""
if [ ! -f "$stamp" ]; then
  # No live stamp: activation archived it (incident closed) or nothing soaks.
  verdict="green"
else
  status="$(jq -r '.status // ""' "$stamp")"
  digest="$(jq -r '.digest // ""' "$stamp")"
  case "$status" in
    soak_red)
      if [ "$attempt" -ge "$max_attempts" ]; then
        verdict="exhausted"
      else
        verdict="red"
      fi
      ;;
    soaking) verdict="soaking" ;;
    *) verdict="green" ;;
  esac
fi

# Red probe output for the FIX brief, when host-track kept one.
if [ -n "$digest" ] && [ -f "$stamp_dir/soak-history/last-probe-$app.log" ]; then
  probe_tail="$(tail -c 2000 "$stamp_dir/soak-history/last-probe-$app.log" | tr -d '\000')"
fi

jq -cn --arg verdict "$verdict" --arg app "$app" --arg digest "$digest" \
  --arg probe "$probe_tail" --argjson attempt "$attempt" \
  '{verdict:$verdict, app:$app, digest:$digest, probe_tail:$probe, attempt:$attempt}' \
  | sed 's/^/LOOM_CONTEXT_PATCH:/'
echo "soak-collect app=$app verdict=$verdict digest=${digest:0:12} attempt=$attempt"
