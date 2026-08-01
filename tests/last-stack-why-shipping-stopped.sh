#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-why-shipping-stopped"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

chmod +x "$bin" 2>/dev/null || true
PYTHONPYCACHEPREFIX="$tmp/pycache" python3 -m py_compile "$bin"
"$bin" --help >/dev/null

run_case() {
  local name="$1"
  local expected="$2"
  local line="$3"
  local hb="$tmp/${name}.log"
  local out rc actual
  printf '%s\n' "$line" >"$hb"
  set +e
  out="$("$bin" --no-live --since-min 0 --heartbeats "$hb" --json)"
  rc=$?
  set -e
  actual="$(printf '%s\n' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["class"])')"
  if [ "$actual" != "$expected" ]; then
    echo "expected class $expected for $name, got $actual" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  if [ "$expected" = "none" ] && [ "$rc" -ne 0 ]; then
    echo "expected rc 0 for healthy case, got $rc" >&2
    exit 1
  fi
  if [ "$expected" != "none" ] && [ "$rc" -eq 0 ]; then
    echo "expected nonzero rc for stalled case $name" >&2
    exit 1
  fi
}

run_case healthy none "kanban-pickup 2026-08-01T00:00:00Z ok cards=1 worked=x result=merged pr=lastgit://last-stack/cr/cr-ok"
run_case class_a A "kanban-pickup 2026-08-01T00:00:00Z noop stale-last-stack-install class-a-heal-failed no_card_claimed todo_count=8"
run_case class_b B "kanban-pickup 2026-08-01T00:00:00Z ok cards=1 worked=x result=rolled-back-todo reason=command-timebox pr=none"
run_case class_c C "kanban-pickup 2026-08-01T00:00:00Z ok cards=1 worked=x result=in-flight-ci-pending pr=lastgit://last-stack/cr/cr-1 ci_status=missing"
run_case class_d D "kanban-pickup 2026-08-01T00:00:00Z ok cards=1 worked=x result=in-flight-deploy-pending reason=awaiting_safe_upgrade_live_measurement"
run_case class_e E "kanban-pickup 2026-08-01T00:00:00Z noop busy-node service_timeout no_card_claimed"

echo "ok last-stack-why-shipping-stopped"
