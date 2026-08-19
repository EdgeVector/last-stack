#!/usr/bin/env bash
# Unresolved lastsecrets OBS_SENTRY_DSN locators must not reach child CLIs
# or print on the default observability path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  /bin/rm -rf "$tmp"
}
trap cleanup EXIT

chmod +x "$ROOT/bin/last-stack-obs-exec"

printf '#!/bin/sh\nprintf "dsn=%%s\\n" "${OBS_SENTRY_DSN-UNSET}"\n' > "$tmp/print-dsn"
chmod +x "$tmp/print-dsn"

# Locator is stripped.
out="$(OBS_SENTRY_DSN=lastsecrets://obs-sentry-dsn-routines \
  "$ROOT/bin/last-stack-obs-exec" "$tmp/print-dsn")"
test "$out" = "dsn=UNSET"

# lastsecrets: without // is also stripped.
out="$(OBS_SENTRY_DSN='lastsecrets:obs-sentry-dsn-routines' \
  "$ROOT/bin/last-stack-obs-exec" "$tmp/print-dsn")"
test "$out" = "dsn=UNSET"

# Real https DSN is preserved.
out="$(OBS_SENTRY_DSN='https://public@example.invalid/1' \
  "$ROOT/bin/last-stack-obs-exec" "$tmp/print-dsn")"
test "$out" = "dsn=https://public@example.invalid/1"

# last_stack_run_tool re-strips even if a snippet re-exported the locator.
# shellcheck disable=SC1091
. "$ROOT/bin/last-stack-shell-prelude"
OBS_SENTRY_DSN=lastsecrets://obs-sentry-dsn-routines
export OBS_SENTRY_DSN
out="$(last_stack_run_tool "$tmp/print-dsn")"
test "$out" = "dsn=UNSET"

if command -v bun >/dev/null 2>&1; then
  bun test "$ROOT/tests/observability/sentry.test.ts"

  cat > "$tmp/init-probe.ts" <<EOF
import { initSentry } from "$ROOT/lib/observability/sentry.ts";
const result = await initSentry({
  service: "probe",
  env: { OBS_SENTRY_DSN: "lastsecrets://obs-sentry-dsn-routines" },
  sentryModule: { init() {}, captureException() {}, async flush() { return true; } },
  installProcessHandlers: false,
});
process.stdout.write(JSON.stringify(result) + "\\n");
EOF
  probe_out="$tmp/probe.out"
  probe_err="$tmp/probe.err"
  set +e
  bun "$tmp/init-probe.ts" >"$probe_out" 2>"$probe_err"
  probe_rc=$?
  set -e
  test "$probe_rc" -eq 0
  grep -q '"reason":"invalid_dsn"' "$probe_out"
  if grep -q observability "$probe_out"; then
    echo "expected no observability line on stdout" >&2
    cat "$probe_out" >&2
    exit 1
  fi
  if grep -q observability "$probe_err"; then
    echo "expected no observability warning on default stderr" >&2
    cat "$probe_err" >&2
    exit 1
  fi
fi

echo "ok"
