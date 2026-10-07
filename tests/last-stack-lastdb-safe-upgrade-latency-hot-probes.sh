#!/usr/bin/env bash
# Prove the hot-test guard can fail. A no-op patch is not a pass.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
probe="$ROOT/bin/last-stack-mutation-probe"
cd "$ROOT"
"$probe" --name lat-hot-drop-prior \
  --target skills/lastdb-safe-upgrade/scripts/latency-bar-checks.sh \
  --patch "python3 tests/probes/lat-hot-drop-prior.py" \
  --test "bash tests/last-stack-lastdb-safe-upgrade-latency-bar.sh" \
  --expect-red-on 'FAIL: a first call is not a hot test'
"$probe" --name lat-hot-drop-file-open \
  --target skills/lastdb-safe-upgrade/scripts/latency-bar-checks.sh \
  --patch "python3 tests/probes/lat-hot-drop-file-open.py" \
  --test "bash tests/last-stack-lastdb-safe-upgrade-latency-bar.sh" \
  --expect-red-on 'FAIL: a call that opens files is not a hot test'
"$probe" --name latency-pairs-drop-file-gate \
  --target skills/lastdb-safe-upgrade/scripts/latency-paired-samples.sh \
  --patch "python3 tests/probes/latency-pairs-drop-file-gate.py" \
  --test "bash tests/last-stack-lastdb-safe-upgrade-paired-samples.sh gate-open" \
  --expect-red-on 'FAIL: a paired sample that opens files is not a hot test'
echo "ok last-stack-lastdb-safe-upgrade-latency-hot-probes"
