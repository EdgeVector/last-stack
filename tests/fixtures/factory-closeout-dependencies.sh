#!/usr/bin/env bash
# Private consumer fixtures supply their external contract and batch response.
fixture_closeout_dependencies() {
  local stack="$1" board="$2"
  export BOARD_CLOSEOUT_FIXTURE_BOARD="$board"
  cat > "$stack/bin/last-stack-factory-repair-contract" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"version":1,"result":"ok","contract_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","protected_card_keys":["factory-scoped-dispatch-20261008","factory-guarded-closeout-20261008","factory-canonical-active-counts-20261008","factory-repair-controller-20261009"]}'
SH
  cat > "$stack/bin/last-stack-kanban-show-batch" <<'SH'
#!/usr/bin/env bash
exec "$BOARD_CLOSEOUT_FIXTURE_BOARD" list --column doing --json
SH
  chmod +x "$stack/bin/last-stack-factory-repair-contract" "$stack/bin/last-stack-kanban-show-batch"
}
