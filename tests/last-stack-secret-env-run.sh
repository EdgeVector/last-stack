#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-secret-env-run"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-secret-env-run.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

fixture_secret='fixture-dev-api-key-not-real'

cat >"$WORK/bin/lastsecrets" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LASTSECRETS_ARG_LOG"
case "${1:-}:${2:-}" in
  get:app-registry-dogfood-dev) printf '%s\n' 'fixture-dev-api-key-not-real' ;;
  get:multiline) printf 'first\nsecond\n' ;;
  *) exit 1 ;;
esac
EOF

cat >"$WORK/bin/consumer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${EXEMEM_DEV_API_KEY:-}" = 'fixture-dev-api-key-not-real' ]
[ "${1:-}" = 'ordinary-argument' ]
printf '%s\n' "$0 $*" >"$CONSUMER_ARG_LOG"
printf '%s\n' 'PASS child received secret'
EOF

chmod +x "$WORK/bin/lastsecrets" "$WORK/bin/consumer"
export LASTSECRETS_CLI="$WORK/bin/lastsecrets"
export LASTSECRETS_ARG_LOG="$WORK/lastsecrets-args.log"
export CONSUMER_ARG_LOG="$WORK/consumer-args.log"
export OBS_SENTRY_DSN=lastsecrets://public-observability-locator
unset EXEMEM_DEV_API_KEY || true

output="$(
  "$BIN" \
    --env EXEMEM_DEV_API_KEY \
    --ref lastsecrets://app-registry-dogfood-dev \
    -- "$WORK/bin/consumer" ordinary-argument
)"
[ "$output" = 'PASS child received secret' ]
[ -z "${EXEMEM_DEV_API_KEY:-}" ]
grep -Fxq 'get app-registry-dogfood-dev' "$LASTSECRETS_ARG_LOG"
if rg -n --fixed-strings "$fixture_secret" \
  "$LASTSECRETS_ARG_LOG" "$CONSUMER_ARG_LOG"; then
  echo "secret leaked into command arguments" >&2
  exit 1
fi

if "$BIN" --env 'BAD-NAME' --ref lastsecrets://app-registry-dogfood-dev -- true >/dev/null 2>&1; then
  echo "invalid environment variable name unexpectedly passed" >&2
  exit 1
fi
if "$BIN" --env EXEMEM_DEV_API_KEY --ref raw-value -- true >/dev/null 2>&1; then
  echo "raw secret reference unexpectedly passed" >&2
  exit 1
fi
if "$BIN" --env EXEMEM_DEV_API_KEY --ref lastsecrets://multiline -- true >/dev/null 2>&1; then
  echo "multiline secret unexpectedly passed" >&2
  exit 1
fi

"$BIN" --help | grep -q '^Usage:'
echo "PASS last-stack-secret-env-run"
