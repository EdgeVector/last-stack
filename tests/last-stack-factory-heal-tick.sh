#!/usr/bin/env bash
# A factory-heal execution must be ticked every hour, not only on an hour that
# alerts. Before 2026-09-03 the `sm tick` call sat inside the `and alerts` gate,
# so a heal started on an alerting hour stalled mid-flight once the board went
# quiet (exec_29bd266a6bbf4fb8 sat in VERIFY 21:19Z-23:09Z), and its
# concurrency key then refused the next start.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-factory-health"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/factory-heal-tick.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

# Stub both names the tool probes for, recording every invocation.
for name in state-machine sm; do
  cat > "$tmp/$name" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$tmp/sm-calls"
exit 0
STUB
  chmod +x "$tmp/$name"
done
: > "$tmp/sm-calls"

cat > "$tmp/driver.py" <<PY
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_loader(
    "fh", importlib.machinery.SourceFileLoader("fh", "$bin")
)
fh = importlib.util.module_from_spec(spec)
sys.modules["fh"] = fh
spec.loader.exec_module(fh)
cfg = {"auto_fix": {"enabled": True, "actions": ["factory_heal"]}}
# alerts EMPTY: the quiet hour that used to skip the tick entirely.
print(fh.maybe_auto_fix(cfg, [], pathlib.Path("$ROOT"), False))
PY

PATH="$tmp:$PATH" python3 "$tmp/driver.py" > "$tmp/out" 2>"$tmp/err" || {
  echo "FAIL: driver errored"; cat "$tmp/err"; exit 1;
}

grep -q "tick --definition factory-heal" "$tmp/sm-calls" \
  || { echo "FAIL: quiet hour did not tick factory-heal"; cat "$tmp/sm-calls"; exit 1; }
grep -q "^start factory-heal" "$tmp/sm-calls" \
  && { echo "FAIL: quiet hour must not START a heal"; cat "$tmp/sm-calls"; exit 1; }
grep -q "factory_heal:start=skip" "$tmp/out" \
  || { echo "FAIL: quiet hour should report start=skip"; cat "$tmp/out"; exit 1; }

# An alerting hour must still start AND tick.
: > "$tmp/sm-calls"
cat > "$tmp/driver2.py" <<PY
import importlib.util, sys, pathlib
spec = importlib.util.spec_from_loader(
    "fh", importlib.machinery.SourceFileLoader("fh", "$bin")
)
fh = importlib.util.module_from_spec(spec)
sys.modules["fh"] = fh
spec.loader.exec_module(fh)
cfg = {"auto_fix": {"enabled": True, "actions": ["factory_heal"]}}
alert = fh.Alert(severity="hard", code="ship_rate_hard", title="t", detail="d")
print(fh.maybe_auto_fix(cfg, [alert], pathlib.Path("$ROOT"), False))
PY
PATH="$tmp:$PATH" python3 "$tmp/driver2.py" > "$tmp/out2" 2>"$tmp/err2" || {
  echo "FAIL: alerting driver errored"; cat "$tmp/err2"; exit 1;
}
grep -q "^start factory-heal" "$tmp/sm-calls" \
  || { echo "FAIL: alerting hour did not start a heal"; cat "$tmp/sm-calls"; exit 1; }
grep -q "tick --definition factory-heal" "$tmp/sm-calls" \
  || { echo "FAIL: alerting hour did not tick"; cat "$tmp/sm-calls"; exit 1; }

echo "ok last-stack-factory-heal-tick"
