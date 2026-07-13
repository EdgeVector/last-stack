#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/brain" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$FAKE_FBRain_ARGS"

cmd="$1"
shift
case "$cmd" in
  get)
    slug="$1"
    shift
    typed=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --type)
          [ "${2:-}" = "reference" ] && typed=1
          shift 2
          ;;
        --type=reference)
          typed=1
          shift
          ;;
        *)
          shift
          ;;
      esac
    done
    [ "$slug" = "routine-heartbeats" ] || exit 22
    if [ "${FAKE_FBRain_READ_FAIL:-0}" = "1" ]; then
      printf '{"error":"read_failed","hint":"simulated failure"}\n'
      exit 1
    fi
    if [ "${FAKE_FBRain_SCHEMA_FAIL:-0}" = "1" ]; then
      printf 'error: No canonical hash registered for type "decision" in config.\n'
      printf 'hint:  Re-run `brain init` so the config picks up all 10 schema hashes.\n'
      exit 1
    fi
    if [ "$typed" -ne 1 ]; then
      printf '{"error":"ambiguous_slug","hint":"project and reference both exist"}\n'
      exit 1
    fi
    printf '{"slug":"routine-heartbeats","type":"reference","body":"old-one\\nold-two"}\n'
    ;;
  put)
    slug="$1"
    shift
    typed=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --type)
          [ "${2:-}" = "reference" ] && typed=1
          shift 2
          ;;
        --type=reference)
          typed=1
          shift
          ;;
        --json)
          shift
          ;;
        *)
          shift
          ;;
      esac
    done
    [ "$slug" = "routine-heartbeats" ] || exit 22
    [ "$typed" -eq 1 ] || exit 23
    cat > "$FAKE_FBRain_PUT_BODY"
    printf '{"ok":true,"slug":"routine-heartbeats","created":false}\n'
    ;;
  append)
    slug="$1"
    shift
    typed=0
    raw=0
    json=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --type)
          [ "${2:-}" = "reference" ] && typed=1
          shift 2
          ;;
        --type=reference)
          typed=1
          shift
          ;;
        --raw)
          raw=1
          shift
          ;;
        --json)
          json=1
          shift
          ;;
        *)
          shift
          ;;
      esac
    done
    [ "$slug" = "routine-heartbeats" ] || exit 22
    [ "$typed" -eq 1 ] || exit 23
    [ "$raw" -eq 1 ] || exit 25
    [ "$json" -eq 1 ] || exit 26
    cat > "$FAKE_FBRain_APPEND_BODY"
    printf '{"ok":true,"slug":"routine-heartbeats","appended":true,"newBodyChars":99}\n'
    ;;
  *)
    exit 24
    ;;
esac
FAKE
chmod +x "$fake_bin/brain"

export PATH="$fake_bin:$PATH"
export FAKE_FBRain_ARGS="$tmp/args"
export FAKE_FBRain_PUT_BODY="$tmp/put-body"
export FAKE_FBRain_APPEND_BODY="$tmp/append-body"

"$ROOT/bin/last-stack-brain-append-heartbeat" --line "new-heartbeat"

grep -q -- 'get routine-heartbeats --type reference --json' "$FAKE_FBRain_ARGS"
grep -q -- 'put routine-heartbeats --type reference --json' "$FAKE_FBRain_ARGS"

expected="$tmp/expected"
printf 'new-heartbeat\nold-one\nold-two\n' > "$expected"
cmp "$expected" "$FAKE_FBRain_PUT_BODY"

rm -f "$FAKE_FBRain_PUT_BODY"
export FAKE_FBRain_READ_FAIL=1
if "$ROOT/bin/last-stack-brain-append-heartbeat" --line "must-not-write" >/dev/null 2>&1; then
  echo "expected read failure" >&2
  exit 1
fi
if [ -e "$FAKE_FBRain_PUT_BODY" ]; then
  echo "helper wrote after a read failure" >&2
  exit 1
fi

rm -f "$FAKE_FBRain_APPEND_BODY" "$FAKE_FBRain_PUT_BODY"
unset FAKE_FBRain_READ_FAIL
export FAKE_FBRain_SCHEMA_FAIL=1
"$ROOT/bin/last-stack-brain-append-heartbeat" --line "schema-drift-heartbeat"

grep -q -- 'append routine-heartbeats --type reference --raw --json' "$FAKE_FBRain_ARGS"
printf '\nschema-drift-heartbeat\n' > "$expected"
cmp "$expected" "$FAKE_FBRain_APPEND_BODY"
if [ -e "$FAKE_FBRain_PUT_BODY" ]; then
  echo "helper used put after schema-config read failure" >&2
  exit 1
fi

echo "ok"
