#!/usr/bin/env bash
# Recovery point and backup soak for the signed-log backup. Source this file.
# Uses the driver's globals ($PRIMARY_SOCK, $PRIMARY_HOME, $WORK) and log/warn/die.
#
# The node uploads each accepted write as one signed entry to a relay and takes
# a snapshot every 25,000 entries or on `lastdb backup snapshot --wait`. The
# facts come from GET /api/status, object status.cloud_sync:
#   connected, environment, captures_accepted, payment_hold, last_error,
#   databases.<id>.upload.{spool_head, spool_confirmed_through, last_error},
#   databases.<id>.download.last_error,
#   snapshot.{state, taken_at_ms, manifest_sha256}.
# `spool_head` is the last accepted write (head). `spool_confirmed_through` is
# the last write the relay confirmed (acked). A missing field is a refusal.
# Design: docs/designs/signed-log-on-local-machinery.md and relay-protocol.md in
# EdgeVector/lastdb.

BACKUP_WAIT_SECS="${LASTDB_BACKUP_WAIT_SECS:-300}"
BACKUP_SNAPSHOT_WAIT_SECS="${LASTDB_BACKUP_SNAPSHOT_WAIT_SECS:-3600}"
# JSON object {"<database id>": <spool head>} read from the OLD build before the stop.
BACKUP_PRESTOP_HEADS=""
BACKUP_PRESTOP_LOCAL_HEAD=""

backup_status_sample() {
  # $1 = output file (fresh, mode 600)
  (umask 077; set -C; : >"$1") || return 1
  curl -fsS --max-time 30 --unix-socket "$PRIMARY_SOCK" \
    -H 'Host: localhost' -H 'X-LastDB-Client: lastdb-safe-upgrade' \
    http://x/api/status >"$1" 2>/dev/null
}

# Print one word for a status file: ok, or the first failed check.
# Cloud sync is connected with no error, and every database it reports has its
# last accepted write confirmed by the relay (acked == head).
backup_sync_verdict() {
  jq -r '
    .status.spool.head as $live_head
    | .status.cloud_sync as $c
    | if .ok != true then "status-not-ok"
      elif ($c | type) != "object" then "cloud-sync-missing"
      elif $c.connected != true then "not-connected"
      elif ($c.environment | type) != "string" or ($c.environment | length) == 0 then "environment-missing"
      elif $c.captures_accepted != true then "captures-not-accepted"
      elif $c.payment_hold != false then "payment-hold"
      elif (.status.spool | type) != "object" then "local-spool-missing"
      elif .status.spool.gap != false then "local-capture-gap"
      elif (.status.spool.head | type) != "number"
          or (.status.spool.acked | type) != "number" then "local-position-missing"
      elif .status.spool.head != .status.spool.acked then "upload-behind"
      elif ($c | has("last_error") | not) then "error-field-missing"
      elif $c.last_error != null then "error"
      elif ($c.databases | type) != "object" or ($c.databases | length) == 0 then "no-database-progress"
      elif any($c.databases[]; (.upload.spool_head | type) != "number"
          or (.upload.spool_confirmed_through | type) != "number") then "upload-position-missing"
      elif any($c.databases[]; .upload.last_error != null or .download.last_error != null) then "database-error"
      elif any($c.databases[]; .upload.spool_head != .upload.spool_confirmed_through) then "upload-behind"
      # A per-database upload.spool_head can itself be a stale mirror of the
      # live local spool, so confirmed == cached-head is not proof the relay
      # has caught up with the spool this sample actually read.
      elif any($c.databases[]; $live_head > .upload.spool_confirmed_through) then "upload-behind"
      else "ok" end
  ' "$1" 2>/dev/null || echo "status-invalid"
}

# Print one word: ok, or why no snapshot is on record.
# The newest snapshot is published or installed, has a time, and names a manifest.
backup_snapshot_verdict() {
  # $1 = status file, $2 = earliest accepted taken_at_ms (0 = any)
  jq -r --argjson since "${2:-0}" '
    .status.cloud_sync.snapshot as $s
    | if ($s | type) != "object" then "snapshot-missing"
      elif $s.state != "published" and $s.state != "installed" then "snapshot-" + ($s.state | tostring)
      elif ($s.taken_at_ms | type) != "number" or $s.taken_at_ms <= 0 then "snapshot-time-missing"
      elif ($s.manifest_sha256 | type) != "string" or ($s.manifest_sha256 | test("^[0-9a-f]{64}$") | not) then "snapshot-manifest-missing"
      elif $s.taken_at_ms < $since then "snapshot-older-than-this-run"
      else "ok" end
  ' "$1" 2>/dev/null || echo "status-invalid"
}

# Recovery point, read from the status JSON of the OLD running build before the
# stop: Cloud sync connected with no error, a snapshot on record, and acked ==
# head for every database. Retries for $BACKUP_WAIT_SECS when the relay is still
# confirming the newest writes. Sets BACKUP_PRESTOP_HEADS. A refusal leaves the
# primary running.
backup_recovery_point_preflight() {
  local status verdict started
  case "$BACKUP_WAIT_SECS" in ''|*[!0-9]*) die "LASTDB_BACKUP_WAIT_SECS must be a whole number" ;; esac
  status="$WORK/pre-stop-backup-status.json"
  started="$(date +%s)"
  while :; do
    rm -f -- "$status"
    backup_status_sample "$status" \
      || die "recovery point: the primary status is unavailable; the primary was not stopped"
    verdict="$(backup_sync_verdict "$status")"
    [ "$verdict" != ok ] || verdict="$(backup_snapshot_verdict "$status" 0)"
    case "$verdict" in
      ok) break ;;
      status-not-ok|status-invalid|cloud-sync-missing|snapshot-missing)
        die "recovery point refused: $verdict; the primary was not stopped" ;;
    esac
    if [ "$(( $(date +%s) - started ))" -ge "$BACKUP_WAIT_SECS" ]; then
      die "recovery point is not current after ${BACKUP_WAIT_SECS}s: $verdict; the primary was not stopped"
    fi
    log "recovery point is not current yet: $verdict; retry in 15s"
    sleep 15
  done
  BACKUP_PRESTOP_HEADS="$(jq -c '[.status.cloud_sync.databases | to_entries[]
    | {key: .key, value: .value.upload.spool_head}] | from_entries' "$status")" \
    || die "recovery point: the database heads cannot be read; the primary was not stopped"
  BACKUP_PRESTOP_LOCAL_HEAD="$(jq -er '.status.spool.head' "$status")" \
    || die "recovery point: the local spool head cannot be read; the primary was not stopped"
  log "recovery point (no copy of the primary): backup connected, a snapshot on record, acked == head for $(jq -r 'length' <<<"$BACKUP_PRESTOP_HEADS") database(s); saved program pair $OLD_PROGRAM_DIR"
}

# After the new build starts: acked follows head again. Every database that was
# there before the stop is reported, its head has not moved back, and acked == head.
backup_following_verdict() {
  jq -r --argjson before "$BACKUP_PRESTOP_HEADS" --argjson local_before "$BACKUP_PRESTOP_LOCAL_HEAD" '
    .status.cloud_sync.databases as $d
    | if (.status.spool.head | type) != "number" then "local-position-missing"
      elif .status.spool.head < $local_before then "local-head-moved-back"
      elif ($d | type) != "object" then "no-database-progress"
      elif any($before | keys[]; ($d[.] | type) != "object") then "database-not-reported-yet"
      elif any($before | to_entries[]; $d[.key].upload.spool_head < .value) then "head-moved-back"
      else "ok" end
  ' "$1" 2>/dev/null || echo "status-invalid"
}

backup_snapshot_wait() {
  # $1 = the new lastdb CLI. One snapshot, returning after its entry is on the relay.
  local cli="$1" out="$WORK/backup-snapshot.out" rc=0
  : >"$out"
  run_op_with_deadline "$BACKUP_SNAPSHOT_WAIT_SECS" \
    env LASTDB_HOME="$PRIMARY_HOME" LASTDB_SOCKET_PATH="$PRIMARY_SOCK" \
    "$cli" backup snapshot --wait >"$out" 2>"$out.err" || rc=$?
  [ "$rc" -eq 0 ] \
    || die "lastdb backup snapshot --wait failed (rc=$rc): $(tail -c 400 "$out.err" | tr '\n' ' ')"
}

# The backup soak after the new build serves: acked follows head again, one
# snapshot succeeds, and the newest snapshot on record is from this run.
backup_post_start_soak() {
  # $1 = the new lastdb CLI
  local cli="$1" status verdict started snapshot_after_ms
  status="$WORK/post-start-backup-status.json"
  started="$(date +%s)"
  while :; do
    rm -f -- "$status"
    if backup_status_sample "$status"; then
      verdict="$(backup_sync_verdict "$status")"
      [ "$verdict" != ok ] || verdict="$(backup_following_verdict "$status")"
    else
      verdict="status-unavailable"
    fi
    [ "$verdict" != ok ] || break
    if [ "$(( $(date +%s) - started ))" -ge "$BACKUP_WAIT_SECS" ]; then
      die "backup did not catch up after the start within ${BACKUP_WAIT_SECS}s: $verdict; recovery = the old program pair $OLD_PROGRAM_DIR"
    fi
    log "backup soak: $verdict; retry in 15s"
    sleep 15
  done
  log "backup soak: acked == head again for every database that existed before the stop"
  snapshot_after_ms="$(( $(date +%s) * 1000 - 1000 ))"
  backup_snapshot_wait "$cli"
  rm -f -- "$status"
  backup_status_sample "$status" \
    || die "backup soak: the primary status is unavailable after the snapshot"
  verdict="$(backup_snapshot_verdict "$status" "$snapshot_after_ms")"
  [ "$verdict" = ok ] || die "backup soak: the snapshot is not on record after snapshot --wait: $verdict"
  log "backup soak: one snapshot --wait succeeded and is on record"
}
