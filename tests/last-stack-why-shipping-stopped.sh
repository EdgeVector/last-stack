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

# 7 handoff + 2 merged + 1 no-op → Class B (pickup window), last no-op stays in evidence.
hb721="$tmp/handoff-window.log"
{
  i=1
  while [ "$i" -le 7 ]; do
    printf 'kanban-pickup 2026-08-20T1%s:00:00Z ok cards=1 worked=s result=in-flight-budget-handoff reason=command-timebox pr=none\n' "$i"
    i=$((i + 1))
  done
  printf '%s\n' "kanban-pickup 2026-08-20T18:00:00Z ok cards=1 worked=a result=merged pr=lastgit://last-stack/cr/cr-a"
  printf '%s\n' "kanban-pickup 2026-08-20T19:00:00Z ok cards=1 worked=b result=merged pr=lastgit://last-stack/cr/cr-b"
  printf '%s\n' "kanban-pickup 2026-08-20T20:00:00Z noop board-read-failed no_card_claimed"
} >"$hb721"
set +e
out721="$("$bin" --no-live --since-min 0 --heartbeats "$hb721" --json)"
rc721=$?
set -e
class721="$(printf '%s\n' "$out721" | python3 -c 'import json,sys; print(json.load(sys.stdin)["class"])')"
heal721="$(printf '%s\n' "$out721" | python3 -c 'import json,sys; print(json.load(sys.stdin)["heal"])')"
if [ "$class721" != "B" ]; then
  echo "expected class B for 7/2/1 fixture, got $class721" >&2
  printf '%s\n' "$out721" >&2
  exit 1
fi
if [ "$rc721" -eq 0 ]; then
  echo "expected nonzero rc for 7/2/1 fixture" >&2
  exit 1
fi
has_noop="$(printf '%s\n' "$out721" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(any("board-read-failed" in (e.get("line") or "") for e in d.get("evidence") or []))')"
if [ "$has_noop" != "True" ]; then
  echo "7/2/1 fixture dropped the last no-op from evidence" >&2
  printf '%s\n' "$out721" >&2
  exit 1
fi
printf '%s\n' "$heal721" | grep -q 'class-a-heal' && {
  echo "7/2/1 fixture heal must not be Class A install-heal" >&2
  printf '%s\n' "$heal721" >&2
  exit 1
}

echo "ok last-stack-why-shipping-stopped"
