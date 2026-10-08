#!/usr/bin/env bash
# Pure hard-delete bar for lastdb-safe-upgrade.
# Sourced by safe-upgrade-lastdb.sh and unit tests. No side effects at source.
# The scoring functions are pure. probe_hard_delete_bar does the copy work.
#
# Why (2026-10-04, execution lx-20261004T210248.912-48120-1): fold f362b8e72
# passed every copy bar, then failed LIVE. A kanban card hard delete failed on
# the persist lane each retry ("hard-erase meter intent changed before
# commit"), the post-cutover status bar read persist-lane-failure, and the
# driver rolled the primary back. The copy workload ran no hard delete, so the
# purge lane was first exercised on the primary.
#
# The driver writes a scratch kanban card on the candidate's CoW copy,
# hard-deletes it with `kanban rm`, and samples /api/status for a bounded
# window that covers the keep_small persist interval (30 s) and one keep_small
# compaction probe (120 s). Every sample must report
# status.resident.persist_lane_failures == 0 and
# status.resident.deferred_persist_failed == 0. Absent fields are RED. A write
# or delete that did not happen is RED. There is no skip.
#
# Brain: papercut-safe-upgrade-probe-runs-no-hard-delete-so-a-purge-lane-defect-reaches-the-primary-20261004
#
# bash 3.2 compatible (macOS /bin/bash). No nested functions.

HARD_DELETE_BAR_SECS="${LASTDB_PROBE_HARD_DELETE_SECS:-150}"
HARD_DELETE_BAR_POLL_SECS="${LASTDB_PROBE_HARD_DELETE_POLL_SECS:-10}"
# A GREEN early exit needs the keep_small compaction stamp to pass the delete
# AND this much time: one keep_small persist interval (30 s) plus margin.
HARD_DELETE_BAR_MIN_SECS="${LASTDB_PROBE_HARD_DELETE_MIN_SECS:-40}"
HARD_DELETE_SLUG_PREFIX="lastdb-safe-upgrade-hard-delete-probe"
# Kanban rm reads by key before the exact delete, so it has its own limit.
HARD_DELETE_KANBAN_DEADLINE_SECS=90
HARD_DELETE_RM_DEADLINE_SECS=180

# $1 = one /api/status capture. Prints "<persist_lane_failures>
# <deferred_persist_failed> <keep_small_last_compacted_at_unix_s>", with -1 for
# an absent or non-integer field.
hard_delete_status_triple() {
  local file="$1"
  jq -r '
    def num:
      if type == "number" and floor == . then floor
      elif type == "string" and test("^[0-9]+$") then tonumber
      elif type == "object" and has("value") then (.value | num)
      else null end;
    def res: (.status.resident // .resident // {});
    [ (res.persist_lane_failures | num) // -1,
      (res.deferred_persist_failed | num) // -1,
      ((.status.sync.capture.automatic_compactions.keep_small.last_compacted_at_unix_s // null) | num) // -1 ]
    | map(tostring) | join(" ")
  ' "$file" 2>/dev/null || printf '%s\n' '-1 -1 -1'
}

# $1 = sample dir (sample-NNN.json), $2 = steps file (key=value lines:
# slug add_rc present rm_rc gone delete_at waited_s), $3 = out path.
# Writes one proof document. Returns 1 when the proof cannot be built.
hard_delete_bar_from_samples() {
  local dir="$1" steps="$2" out="$3" all=""
  local slug="" add_rc="-1" present="0" rm_rc="-1" gone="0" delete_at="0" waited_s="0"
  [ -n "$dir" ] && [ -n "$out" ] || return 1
  if [ -n "$steps" ] && [ -f "$steps" ]; then
    slug="$(sed -n 's/^slug=//p' "$steps" | tail -1)"
    add_rc="$(sed -n 's/^add_rc=//p' "$steps" | tail -1)"
    present="$(sed -n 's/^present=//p' "$steps" | tail -1)"
    rm_rc="$(sed -n 's/^rm_rc=//p' "$steps" | tail -1)"
    gone="$(sed -n 's/^gone=//p' "$steps" | tail -1)"
    delete_at="$(sed -n 's/^delete_at=//p' "$steps" | tail -1)"
    waited_s="$(sed -n 's/^waited_s=//p' "$steps" | tail -1)"
  fi
  case "$add_rc" in ''|*[!0-9]*) add_rc=-1 ;; esac
  case "$rm_rc" in ''|*[!0-9]*) rm_rc=-1 ;; esac
  case "$present" in 1) ;; *) present=0 ;; esac
  case "$gone" in 1) ;; *) gone=0 ;; esac
  case "$delete_at" in ''|*[!0-9]*) delete_at=0 ;; esac
  case "$waited_s" in ''|*[!0-9]*) waited_s=0 ;; esac
  all="$dir/all.json"
  if ! ls "$dir"/sample-*.json >/dev/null 2>&1 \
    || ! jq -s '.' "$dir"/sample-*.json >"$all" 2>/dev/null; then
    printf '%s\n' '[]' >"$all"
  fi
  jq -c --arg slug "$slug" --argjson add_rc "$add_rc" --argjson present "$present" \
    --argjson rm_rc "$rm_rc" --argjson gone "$gone" --argjson delete_at "$delete_at" \
    --argjson waited_s "$waited_s" '
    def num:
      if type == "number" and floor == . then floor
      elif type == "string" and test("^[0-9]+$") then tonumber
      elif type == "object" and has("value") then (.value | num)
      else null end;
    def res: (.status.resident // .resident // {});
    map({
      plf: (res.persist_lane_failures | num),
      dpf: (res.deferred_persist_failed | num)
    }) as $rows
    | {
        proof_kind: "hard-delete",
        slug: $slug,
        add_rc: $add_rc,
        present_after_add: ($present == 1),
        rm_rc: $rm_rc,
        gone_after_rm: ($gone == 1),
        delete_at_unix_s: $delete_at,
        waited_s: $waited_s,
        samples: ($rows | length),
        complete: (($rows | length) > 0
                   and all($rows[]; .plf != null and .dpf != null)),
        max_persist_lane_failures: ([$rows[] | .plf | select(. != null)] | max),
        max_deferred_persist_failed: ([$rows[] | .dpf | select(. != null)] | max)
      }
  ' "$all" >"$out" 2>/dev/null || {
    printf '%s\n' '{}' >"$out"
    return 1
  }
  return 0
}

# $1 = proof document. Prints one GREEN or RED line. Returns 1 on RED.
hard_delete_bar_eval() {
  local file="$1" kind="" slug="" add_rc="" present="" rm_rc="" gone="" samples="" complete="" plf="" dpf="" waited=""
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    printf 'hard-delete bar RED: proof is absent (not skipped)\n'
    return 1
  fi
  kind="$(jq -r '.proof_kind // ""' "$file" 2>/dev/null)"
  if [ "$kind" != "hard-delete" ]; then
    printf 'hard-delete bar RED: proof_kind=%s is not hard-delete (not skipped)\n' "${kind:-absent}"
    return 1
  fi
  slug="$(jq -r '.slug // ""' "$file")"
  add_rc="$(jq -r '.add_rc // -1' "$file")"
  present="$(jq -r '.present_after_add // false' "$file")"
  rm_rc="$(jq -r '.rm_rc // -1' "$file")"
  gone="$(jq -r '.gone_after_rm // false' "$file")"
  samples="$(jq -r '.samples // 0' "$file")"
  complete="$(jq -r '.complete // false' "$file")"
  plf="$(jq -r 'if .max_persist_lane_failures == null then "" else (.max_persist_lane_failures | tostring) end' "$file")"
  dpf="$(jq -r 'if .max_deferred_persist_failed == null then "" else (.max_deferred_persist_failed | tostring) end' "$file")"
  waited="$(jq -r '.waited_s // 0' "$file")"
  if [ "$add_rc" != "0" ]; then
    printf 'hard-delete bar RED: the scratch card write on the copy failed (kanban add rc=%s), so the hard delete never ran (not skipped)\n' "$add_rc"
    return 1
  fi
  if [ "$present" != "true" ]; then
    printf 'hard-delete bar RED: scratch card %s is not readable on the copy after the write, so the hard delete never ran (not skipped)\n' "${slug:-unknown}"
    return 1
  fi
  if [ "$rm_rc" != "0" ]; then
    printf 'hard-delete bar RED: kanban rm %s failed on the copy (rc=%s); the candidate cannot hard-delete a card\n' "${slug:-unknown}" "$rm_rc"
    return 1
  fi
  if [ "$gone" != "true" ]; then
    printf 'hard-delete bar RED: scratch card %s is still readable on the copy after kanban rm; the hard delete did not erase it\n' "${slug:-unknown}"
    return 1
  fi
  case "$samples" in ''|*[!0-9]*) samples=0 ;; esac
  if [ "$samples" -lt 2 ]; then
    printf 'hard-delete bar RED: %s status sample(s) after the hard delete, need at least 2 (not skipped)\n' "$samples"
    return 1
  fi
  if [ "$complete" != "true" ]; then
    printf 'hard-delete bar RED: a sample lacks status.resident.persist_lane_failures or status.resident.deferred_persist_failed (absent fields fail the bar; not skipped)\n'
    return 1
  fi
  case "$plf" in ''|*[!0-9]*) plf=-1 ;; esac
  case "$dpf" in ''|*[!0-9]*) dpf=-1 ;; esac
  if [ "$plf" -ne 0 ]; then
    printf 'hard-delete bar RED: status.resident.persist_lane_failures=%s after the hard delete of %s on the copy; the purge lane fails, and the live primary would fail the same way\n' "$plf" "${slug:-unknown}"
    return 1
  fi
  if [ "$dpf" -ne 0 ]; then
    printf 'hard-delete bar RED: status.resident.deferred_persist_failed=%s after the hard delete of %s on the copy; the purge lane fails, and the live primary would fail the same way\n' "$dpf" "${slug:-unknown}"
    return 1
  fi
  printf 'hard-delete bar GREEN: slug=%s samples=%s waited_s=%s persist_lane_failures=0 deferred_persist_failed=0\n' \
    "$slug" "$samples" "$waited"
  return 0
}

# --- probe step (needs log, warn, probe_copy_is_not_primary, PRIMARY_HOME,
# run_op_with_deadline from the driver; the unit test supplies them) ---------

# kanban against the probe copy only. FOLDDB_SOCKET_PATH wins over every other
# socket source in the kanban CLI (src/config.ts resolveSocketPath), the same
# route op_lat_scan uses. $1 = copy, $2 = copy socket, rest = kanban args.
hd_kanban_on_copy() {
  local copy="$1" sock="$2" deadline="$HARD_DELETE_KANBAN_DEADLINE_SECS"
  shift 2
  [ "${1:-}" != rm ] || deadline="$HARD_DELETE_RM_DEADLINE_SECS"
  run_op_with_deadline "$deadline" env FOLDDB_SOCKET_PATH="$sock" LASTDB_HOME="$copy" FOLDDB_HOME="$copy" \
    kanban "$@"
}

# Log only stage, time, result, and output size. The CLI output can contain
# customer data, so the retained safe-upgrade log never copies its text.
hd_log_step() {
  local stage="$1" rc="$2" started="$3" stdout="$4" stderr="$5"
  local now elapsed stdout_bytes=0 stderr_bytes=0
  now="$(date +%s)"
  elapsed=$((now - started))
  [ ! -f "$stdout" ] || stdout_bytes="$(wc -c <"$stdout" | tr -d '[:space:]')"
  [ ! -f "$stderr" ] || stderr_bytes="$(wc -c <"$stderr" | tr -d '[:space:]')"
  log "hard-delete bar: stage=$stage rc=$rc elapsed_s=$elapsed stdout_bytes=$stdout_bytes stderr_bytes=$stderr_bytes"
}

# Hard-delete bar: on the candidate's CoW copy, write a scratch kanban card,
# hard-delete it (kanban rm), then sample /api/status for a bounded window.
# $1 = copy, $2 = copy socket, $3 = candidate pid, $4 = proof path.
# Writes the proof with hard_delete_bar_from_samples; the main flow scores it
# with hard_delete_bar_eval before any live change. Incident 2026-10-04:
# papercut-safe-upgrade-probe-runs-no-hard-delete-so-a-purge-lane-defect-reaches-the-primary-20261004.
probe_hard_delete_bar() {
  local copy="$1" sock="$2" pid="$3" out="$4"
  local dir steps slug body add_rc=-1 present=0 rm_rc=-1 gone=0 del_at=0 rm_started=0 start now n=0 triple plf dpf ks waited=0
  local step_started show_rc=0
  [ -n "$out" ] || return 1
  if [ -z "$copy" ] || ! probe_copy_is_not_primary "$copy" "$PRIMARY_HOME"; then
    warn "hard-delete bar: copy is the primary home or inside it: ${copy:-unset}; no write"
    return 1
  fi
  case "$sock" in
    "$copy"/*) ;;
    *) warn "hard-delete bar: socket $sock is not inside the copy $copy; no write"; return 1 ;;
  esac
  dir="${copy}.hard-delete-samples"
  steps="$dir/steps.env"
  mkdir -p "$dir"
  slug="${HARD_DELETE_SLUG_PREFIX}-$$"
  printf 'slug=%s\n' "$slug" >"$steps"
  if ! command -v kanban >/dev/null 2>&1; then
    warn "hard-delete bar: kanban CLI not on PATH; the bar is RED (not skipped)"
    hard_delete_bar_from_samples "$dir" "$steps" "$out" || true
    return 0
  fi
  log "hard-delete bar: write scratch card $slug on the candidate copy, then kanban rm it"
  # No set +e/-e here: the caller may hold errexit off, and a set -e at the
  # end would turn it back on under the caller. Each rc is caught with ||.
  # run_op_with_deadline backgrounds the command, so the body goes in --body.
  body="$(printf '%s\n' "Scratch card on the safe-upgrade CoW copy. The probe hard-deletes it." "" \
    "## END STATE" "" "- The probe deleted this card. It never reaches the primary.")"
  step_started="$(date +%s)"
  log "hard-delete bar: stage=add start_unix_s=$step_started"
  add_rc=0
  hd_kanban_on_copy "$copy" "$sock" add "$slug" --title "safe-upgrade hard-delete probe" \
    --column backlog --kind meta --body "$body" >"$dir/add.out" 2>"$dir/add.err" || add_rc=$?
  hd_log_step add "$add_rc" "$step_started" "$dir/add.out" "$dir/add.err"
  if [ "$add_rc" -eq 0 ]; then
    step_started="$(date +%s)"
    log "hard-delete bar: stage=show-before start_unix_s=$step_started"
    show_rc=0
    hd_kanban_on_copy "$copy" "$sock" show "$slug" >"$dir/show-before.out" 2>"$dir/show-before.err" || show_rc=$?
    hd_log_step show-before "$show_rc" "$step_started" "$dir/show-before.out" "$dir/show-before.err"
    [ "$show_rc" -ne 0 ] || present=1
  fi
  if [ "$present" -eq 1 ]; then
    rm_started="$(date +%s)"
    log "hard-delete bar: stage=rm start_unix_s=$rm_started deadline_s=$HARD_DELETE_RM_DEADLINE_SECS"
    rm_rc=0
    hd_kanban_on_copy "$copy" "$sock" rm "$slug" >"$dir/rm.out" 2>"$dir/rm.err" || rm_rc=$?
    if [ "$rm_rc" -eq 0 ]; then
      # The CLI can read for a long time before it sends Delete. Count only
      # a compaction after its successful ack as a post-delete compaction.
      del_at="$(date +%s)"
    fi
    hd_log_step rm "$rm_rc" "$rm_started" "$dir/rm.out" "$dir/rm.err"
    if [ "$rm_rc" -eq 124 ]; then
      warn "hard-delete bar: stage=rm deadline_result=124 deadline_s=$HARD_DELETE_RM_DEADLINE_SECS; the CLI may still have an active request on the candidate copy"
    fi
    if [ "$rm_rc" -eq 0 ]; then
      step_started="$(date +%s)"
      log "hard-delete bar: stage=show-after start_unix_s=$step_started"
      show_rc=0
      hd_kanban_on_copy "$copy" "$sock" show "$slug" >"$dir/show-after.out" 2>"$dir/show-after.err" || show_rc=$?
      hd_log_step show-after "$show_rc" "$step_started" "$dir/show-after.out" "$dir/show-after.err"
      if [ "$show_rc" -ne 0 ] \
        && grep -q 'No card with slug' "$dir/show-after.err" "$dir/show-after.out" 2>/dev/null; then
        gone=1
      fi
    fi
  fi
  printf 'add_rc=%s\npresent=%s\nrm_rc=%s\ngone=%s\ndelete_at=%s\n' \
    "$add_rc" "$present" "$rm_rc" "$gone" "$del_at" >>"$steps"
  if [ "$gone" -eq 1 ]; then
    log "hard-delete bar: sample /api/status up to ${HARD_DELETE_BAR_SECS}s (GREEN early exit after ${HARD_DELETE_BAR_MIN_SECS}s once the keep_small compaction stamp passes the delete)"
    start="$(date +%s)"
    while true; do
      if ! kill -0 "$pid" 2>/dev/null; then
        warn "hard-delete bar: candidate exited after the hard delete"
        break
      fi
      n=$((n + 1))
      curl -sS --max-time 15 --unix-socket "$sock" -H 'Host: localhost' \
        -H 'X-LastDB-Client: lastdb-safe-upgrade' http://x/api/status \
        >"$(printf '%s/sample-%03d.json' "$dir" "$n")" 2>/dev/null \
        || printf '%s\n' '{}' >"$(printf '%s/sample-%03d.json' "$dir" "$n")"
      triple="$(hard_delete_status_triple "$(printf '%s/sample-%03d.json' "$dir" "$n")")"
      plf="${triple%% *}"
      triple="${triple#* }"
      dpf="${triple%% *}"
      ks="${triple#* }"
      now="$(date +%s)"
      waited=$((now - start))
      if [ "$plf" != "0" ] || [ "$dpf" != "0" ]; then
        if [ "$plf" != "-1" ] && [ "$dpf" != "-1" ]; then
          warn "hard-delete bar: persist_lane_failures=$plf deferred_persist_failed=$dpf after ${waited}s; stop the window early"
          break
        fi
      fi
      if [ "$n" -ge 2 ] && [ "$waited" -ge "$HARD_DELETE_BAR_MIN_SECS" ] \
        && [ "$ks" -gt "$del_at" ] 2>/dev/null; then
        log "hard-delete bar: keep_small compaction stamp $ks passed the delete at $del_at"
        break
      fi
      if [ "$waited" -ge "$HARD_DELETE_BAR_SECS" ] && [ "$n" -ge 2 ]; then
        break
      fi
      sleep "$HARD_DELETE_BAR_POLL_SECS"
    done
  else
    warn "hard-delete bar: scratch card write or delete failed on the copy (add_rc=$add_rc present=$present rm_rc=$rm_rc gone=$gone); see $dir"
  fi
  printf 'waited_s=%s\n' "$waited" >>"$steps"
  hard_delete_bar_from_samples "$dir" "$steps" "$out" || true
  return 0
}
