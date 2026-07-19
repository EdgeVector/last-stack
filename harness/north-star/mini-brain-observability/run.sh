#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-mini-brain-observability
MODE="$(ns_mode)"
WS="$(ns_edgevector_workspace)"
FOLD_DIR="${MINI_BRAIN_OBSERVABILITY_PROOF_FOLD_DIR:-$WS/fold}"
LAST_STACK_DIR="${MINI_BRAIN_OBSERVABILITY_PROOF_LAST_STACK_DIR:-$ROOT}"

fail() {
  ns_write_report "$SLUG" FAIL "$1" || exit 1
  exit 1
}

require_file() {
  local path="$1" label="$2"
  [ -f "$path" ] || fail "missing $label: $path"
}

require_text() {
  local path="$1" pattern="$2" label="$3"
  require_file "$path" "$label"
  if ! grep -Eiq "$pattern" "$path"; then
    fail "missing Mini brain observability contract: $label

Path: $path
Pattern: $pattern"
  fi
}

status_cli="$FOLD_DIR/lastdb_node/src/bin/lastdb.rs"
crash="$FOLD_DIR/lastdb_node/src/ops/crash_attribution.rs"
self_metrics="$FOLD_DIR/lastdb_node/src/ops/self_metrics.rs"
session_ledger="$FOLD_DIR/lastdb_node/src/ops/session_ledger.rs"
daemon_main="$FOLD_DIR/lastdb_node/src/main.rs"
dashboard="$FOLD_DIR/scripts/lastdbd/telemetry-dashboard-regen.sh"
alert="$FOLD_DIR/scripts/lastdbd/mini-health-alert-check.sh"
dogfood_rotate="$LAST_STACK_DIR/routines/dogfood-rotate.md"

require_text "$status_cli" 'fn status\(data_dir: Option<PathBuf>\)' 'lastdb status entrypoint'
require_text "$status_cli" 'crash_attribution::daemon_status_line' 'status prints daemon liveness'
require_text "$status_cli" 'crash_attribution::status_lines' 'status prints uptime and previous exit'
require_text "$status_cli" 'self_metrics::status_lines' 'status prints memory, CPU, sampler, and sync health'
require_text "$status_cli" 'request_ops_lines' 'status includes request-ops offender summary'
require_text "$status_cli" 'GET /api/status|probe_status' 'status reads the structured status snapshot'
require_text "$status_cli" 'X-LastDB-Client: lastdb' 'status self-identifies to request telemetry'
require_text "$status_cli" 'fn alert_check\(data_dir: Option<PathBuf>' 'alert-check CLI exists'

require_text "$crash" 'install_crash_hook' 'daemon installs crash report hook'
require_text "$crash" 'promote_previous_crash_evidence' 'previous crashes are promoted'
require_text "$crash" 'previous_log_tail' 'unclean exits include previous log tail'
require_text "$crash" 'status_lines' 'crash/session ledger feeds lastdb status'
require_text "$crash" 'Sentry|sentry' 'crash evidence has Sentry surface'
require_text "$crash" 'unclean' 'unclean exit attribution is represented'

require_text "$session_ledger" 'live.*session|SessionRecord|prev_session_clean' 'session ledger records clean versus unclean sessions'
require_text "$daemon_main" 'install_crash_hook' 'lastdbd boot installs crash hook'
require_text "$daemon_main" 'promote_previous_crash_evidence' 'lastdbd boot promotes prior crash evidence'

require_text "$self_metrics" 'StatusSnapshot' 'structured status snapshot type'
require_text "$self_metrics" 'rss_bytes' 'RSS memory field'
require_text "$self_metrics" 'cpu_percent' 'CPU field'
require_text "$self_metrics" 'sync_last_success_ts|last_success_ts' 'sync last success field'
require_text "$self_metrics" 'sync_pending_count|pending_count' 'sync pending/backlog field'
require_text "$self_metrics" 'DEFAULT_SELF_METRICS_LOG_REL' 'out-of-band self-metrics history log'
require_text "$self_metrics" 'SELF_METRIC_SCHEMA' 'LastDB self-metrics schema'
require_text "$self_metrics" 'LASTDB_SELF_METRICS_TO_DB' 'optional self-metrics write into LastDB'
require_text "$self_metrics" 'request_ops' 'request-ops history/status surface'

require_text "$dashboard" 'telemetry-dashboard' 'dashboard regeneration command'
require_text "$dashboard" 'DASHBOARD_HTML=' 'dashboard command reports generated HTML'
require_text "$dashboard" 'LASTDB_HOME' 'dashboard regen can target a throwaway home'

require_text "$alert" 'alert-check' 'health alert wrapper calls lastdb alert-check'
require_text "$alert" 'LASTDB_HEALTH_ALERT_FAILURES_BEFORE_ALERT' 'alert threshold is configurable'
require_text "$alert" 'heartbeat' 'alert path can publish routine heartbeat'

require_text "$dogfood_rotate" 'dogfood-registry' 'dogfood registry rotation exists'
require_text "$dogfood_rotate" 'dogfood exactly one eligible feature|eligible feature from the Brain-owned' 'dogfood rotation exercises registered product features'

notes="$(cat <<EOF
Mini brain observability source contract verified.

Mode: $MODE
Fold source: $FOLD_DIR
LastStack source: $LAST_STACK_DIR

Covered end-state surfaces:
- \`lastdb status\` prints daemon liveness, uptime, previous-session exit cause, RSS, CPU, data-dir size, sync health/backlog, sampler state, QoS/UDS state, and request-ops offenders.
- Crash/session attribution is wired through the daemon boot path: panic reports, previous log tail, unclean-exit attribution, and Sentry promotion.
- Self-metrics history exists as an out-of-band JSONL log plus optional LastDB records under \`lastdb_telemetry/SelfMetricSample\`.
- Dashboard regeneration is a first-class script and can target a throwaway \`LASTDB_HOME\`.
- Proactive health alerting is wired through \`lastdb alert-check\` with configurable thresholds, state files, notification logs, and heartbeat hooks.
- Dogfood rotation has a Brain-owned registry path for exercising product hooks without embedding a live registry read in this offline proof.

Offline proof policy:
- This harness performs source/contract checks only.
- It does not open, restart, kill, or write to the primary \`~/.lastdb\` daemon.
- Live operational completion still belongs to the Fold cards named by this North Star.
EOF
)"

verdict=PASS
[ "$MODE" = offline ] && verdict=PASS-OFFLINE
ns_write_report "$SLUG" "$verdict" "$notes"
