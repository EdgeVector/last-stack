#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-dogfood-rotate-gate"
chmod +x "$GATE"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

cat >"$tmp/pass.sh" <<'EOF'
#!/usr/bin/env bash
printf 'PASS\n'
EOF
chmod +x "$tmp/pass.sh"

cat >"$tmp/registry.md" <<EOF
# Dogfood Registry -- rotation queue

## Features

### molecule-per-key-reads · track: build · cadence: 24h
- **eligible:** true
- **timeout_sec:** 180
- **requires:** compile
- **command:** cargo build -p lastdb_node && cargo bench --bench query_path_bench

### schema-service-dev-propose · track: build · cadence: 24h
- **eligible:** true
- **timeout_sec:** 30
- **requires:** none
- **command:** $tmp/pass.sh

### discovery-full-bar-slice · track: build · cadence: 24h
- **eligible:** true
- **timeout_sec:** 30
- **requires:** staged-lastdbd
- **command:** $tmp/pass.sh

### lastdbd-status-attribution · track: build · cadence: 24h
- **eligible:** false
- **timeout_sec:** 180
- **requires:** staged-lastdbd
- **command:** $tmp/pass.sh

### app-registry-publish-flow · track: build · cadence: 24h
- **eligible:** false
- **auto-rotation:** false
- **timeout_sec:** 180
- **requires:** lastsecrets://exemem-dev-api-key
- **command:** $tmp/pass.sh

### cloud-backup-restore · track: maintain · cadence: 24h
- **What:** dedicated backup-restore-probe owns this.

## Retired / ineligible auto-rotation surfaces
- **cloud-backup-restore** — \`status: retired\`; \`eligible: false\`; \`auto-rotation: false\`. Dedicated probe owns this.
- **app-registry-publish-flow** — live DEV credential is not lastsecrets-backed.

<!-- rotation-log:start -->
| feature | last_run | result | cards filed |
|---|---|---|---|
| molecule-per-key-reads | 2026-01-01 | blocked | -- |
| schema-service-dev-propose | 2026-01-01 | fail | -- |
| discovery-full-bar-slice | 2026-01-01 | fail | -- |
| lastdbd-status-attribution | 2026-01-01 | fail | -- |
| app-registry-publish-flow | 2026-01-01 | recipe-broken | -- |
| cloud-backup-restore | 2026-01-01 | blocked | -- |
<!-- rotation-log:end -->
EOF

# Force staged-lastdbd unmet so this host's real canary tree cannot flake the
# compile/ineligible assertions by making discovery selectable.
export LAST_STACK_DOGFOOD_GATE_STAGED_LASTDBD=0
out="$("$GATE" --registry-file "$tmp/registry.md" --now 2026-08-20T00:00:00Z)"
printf '%s\n' "$out" | grep -q $'^SKIPPED\tfeature=molecule-per-key-reads\treason=requires-compile$' \
  || fail "compile recipe must be skipped: $out"
printf '%s\n' "$out" | grep -q $'^SKIPPED\tfeature=lastdbd-status-attribution\treason=ineligible$' \
  || fail "eligible:false must be skipped: $out"
printf '%s\n' "$out" | grep -q $'^SKIPPED\tfeature=app-registry-publish-flow\treason=ineligible$' \
  || fail "auto-rotation false must be skipped: $out"
printf '%s\n' "$out" | grep -q $'^SKIPPED\tfeature=cloud-backup-restore\treason=ineligible$' \
  || fail "retired slug must be skipped: $out"
printf '%s\n' "$out" | grep -q $'^SKIPPED\tfeature=discovery-full-bar-slice\treason=need_build$' \
  || fail "missing staged lastdbd must skip discovery: $out"
printf '%s\n' "$out" | grep -q $'^SELECTED\tfeature=schema-service-dev-propose\t' \
  || fail "runnable HTTP recipe should be selected: $out"
printf '%s\n' "$out" | grep -q 'command=cargo' && fail "SELECTED command must never contain cargo: $out"
printf '%s\n' "$out" | grep -q $'^RESULT\toutcome=ok\tdetail=selected=schema-service-dev-propose$' \
  || fail "dry-run result: $out"

# With staged lastdbd present, discovery is also runnable; schema is first in
# overdue-tie registry order... both are infinitely overdue from 2026-01-01.
# schema-service-dev-propose sorts first on equal inf overdue (slug). Keep
# that stable: SELECTED stays schema unless we drop it.
out_ok="$("$GATE" --registry-file "$tmp/registry.md" --now 2026-08-20T00:00:00Z --run --cwd "$tmp")"
# schema is still the only runnable entry under LAST_STACK_DOGFOOD_GATE_STAGED_LASTDBD=0
printf '%s\n' "$out_ok" | grep -q $'result=pass exit=0' \
  || fail "runnable command should pass: $out_ok"

# Negative: only compile + ineligible entries → noop, never selected.
cat >"$tmp/compile-only.md" <<'EOF'
# Dogfood Registry

## Features

### molecule-per-key-reads · cadence: 24h
- eligible: true
- requires: none
- command: cargo build -p lastdb_node

<!-- rotation-log:start -->
| feature | last_run | result | cards filed |
|---|---|---|---|
| molecule-per-key-reads | -- | -- | -- |
<!-- rotation-log:end -->
EOF
out_compile="$("$GATE" --registry-file "$tmp/compile-only.md" --now 2026-08-20T00:00:00Z --run)"
printf '%s\n' "$out_compile" | grep -q $'^SKIPPED\tfeature=molecule-per-key-reads\treason=requires-compile$' \
  || fail "bare cargo command must skip: $out_compile"
printf '%s\n' "$out_compile" | grep -q $'^RESULT\toutcome=noop\tdetail=no-runnable-entry$' \
  || fail "compile-only registry must noop: $out_compile"
printf '%s\n' "$out_compile" | grep -q '^SELECTED' && fail "compile-only must not SELECT: $out_compile"

# Discovery becomes selectable once staged lastdbd is assumed present and
# schema is marked not-due via a fresh last_run.
cat >"$tmp/discovery.md" <<EOF
# Dogfood Registry

## Features

### schema-service-dev-propose · cadence: 24h
- eligible: true
- requires: none
- command: $tmp/pass.sh

### discovery-full-bar-slice · cadence: 24h
- eligible: true
- requires: staged-lastdbd
- command: $tmp/pass.sh

<!-- rotation-log:start -->
| feature | last_run | result | cards filed |
|---|---|---|---|
| schema-service-dev-propose | 2026-08-20 | pass | -- |
| discovery-full-bar-slice | 2026-01-01 | fail | -- |
<!-- rotation-log:end -->
EOF
out_disc="$(LAST_STACK_DOGFOOD_GATE_STAGED_LASTDBD=1 \
  "$GATE" --registry-file "$tmp/discovery.md" --now 2026-08-20T12:00:00Z)"
printf '%s\n' "$out_disc" | grep -q $'^SKIPPED\tfeature=schema-service-dev-propose\treason=not-due\t' \
  || fail "fresh last_run should be not-due: $out_disc"
printf '%s\n' "$out_disc" | grep -q $'^SELECTED\tfeature=discovery-full-bar-slice\t' \
  || fail "discovery with staged lastdbd should select: $out_disc"

# --routines-dispatch is the skip-harness producer: ROUTINE_RESULT + exit 0,
# never a cargo SELECTED command.
export LAST_STACK_DOGFOOD_GATE_SKIP_HEARTBEAT=1
dispatch_ok="$("$GATE" --registry-file "$tmp/registry.md" --now 2026-08-20T00:00:00Z --routines-dispatch --cwd "$tmp")"
printf '%s\n' "$dispatch_ok" | grep -q $'^SELECTED\tfeature=schema-service-dev-propose\t' \
  || fail "dispatch should select runnable recipe: $dispatch_ok"
printf '%s\n' "$dispatch_ok" | grep -q 'ROUTINE_RESULT outcome=ok detail=feature=schema-service-dev-propose result=pass cards=0' \
  || fail "dispatch must emit skip-harness trailer: $dispatch_ok"
printf '%s\n' "$dispatch_ok" | grep -q 'command=cargo' && fail "dispatch SELECTED must never contain cargo: $dispatch_ok"

dispatch_noop="$("$GATE" --registry-file "$tmp/compile-only.md" --now 2026-08-20T00:00:00Z --routines-dispatch)"
printf '%s\n' "$dispatch_noop" | grep -q 'ROUTINE_RESULT outcome=noop detail=feature=- result=no-runnable-entry cards=0' \
  || fail "compile-only dispatch must noop-skip harness: $dispatch_noop"
printf '%s\n' "$dispatch_noop" | grep -q '^SELECTED' && fail "compile-only dispatch must not SELECT: $dispatch_noop"

# A busy node is a load signal, not a gate failure. `brain get` that overruns
# its timeout used to escape as subprocess.TimeoutExpired (the only handler was
# `except OSError`), so routinesd recorded outcome=error with a traceback.
# Both busy shapes must now produce exit 0 and an honest noop.
cat >"$tmp/brain-hang" <<'EOF'
#!/usr/bin/env bash
sleep 120
EOF
chmod +x "$tmp/brain-hang"

cat >"$tmp/brain-busy" <<'EOF'
#!/usr/bin/env bash
echo "service_timeout: node did not respond within 30000ms" >&2
exit 1
EOF
chmod +x "$tmp/brain-busy"

# Drive the brain-get bound down: Forge CI already runs near its ceiling, so
# the proof must not sleep out the 30s production timeout.
set +e
out_hang="$(LAST_STACK_DOGFOOD_GATE_BRAIN_TIMEOUT_SEC=2 \
  timeout 60 "$GATE" --brain-bin "$tmp/brain-hang" --now 2026-08-20T00:00:00Z --routines-dispatch)"
rc_hang=$?
set -e
[ "$rc_hang" -eq 0 ] || fail "brain-get timeout must exit 0, got $rc_hang: $out_hang"
printf '%s\n' "$out_hang" | grep -q 'ROUTINE_RESULT outcome=noop detail=feature=- result=registry-unavailable cards=0' \
  || fail "brain-get timeout must emit a noop trailer: $out_hang"
printf '%s\n' "$out_hang" | grep -q 'reason=brain-get-timeout-2s' \
  || fail "brain-get timeout must name its reason: $out_hang"
printf '%s\n' "$out_hang" | grep -qi 'Traceback' && fail "brain-get timeout must not traceback: $out_hang"

set +e
out_busy="$("$GATE" --brain-bin "$tmp/brain-busy" --now 2026-08-20T00:00:00Z --routines-dispatch)"
rc_busy=$?
set -e
[ "$rc_busy" -eq 0 ] || fail "service_timeout must exit 0, got $rc_busy: $out_busy"
printf '%s\n' "$out_busy" | grep -q 'reason=brain-get-busy-node' \
  || fail "service_timeout must map to busy-node noop: $out_busy"

# A genuine brain failure is still a gate error, not a silent noop.
cat >"$tmp/brain-broken" <<'EOF'
#!/usr/bin/env bash
echo "record not found" >&2
exit 1
EOF
chmod +x "$tmp/brain-broken"
set +e
out_broken="$("$GATE" --brain-bin "$tmp/brain-broken" --now 2026-08-20T00:00:00Z --routines-dispatch 2>/dev/null)"
rc_broken=$?
set -e
[ "$rc_broken" -eq 1 ] || fail "a real brain failure must stay exit 1, got $rc_broken: $out_broken"

python3 -m py_compile "$GATE"
echo OK last-stack-dogfood-rotate-gate
