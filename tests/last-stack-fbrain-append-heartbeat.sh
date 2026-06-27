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

cat > "$fake_bin/fbrain" <<'FAKE'
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
  *)
    exit 24
    ;;
esac
FAKE
chmod +x "$fake_bin/fbrain"

export PATH="$fake_bin:$PATH"
export FAKE_FBRain_ARGS="$tmp/args"
export FAKE_FBRain_PUT_BODY="$tmp/put-body"

"$ROOT/bin/last-stack-fbrain-append-heartbeat" --line "new-heartbeat"

grep -q -- 'get routine-heartbeats --type reference --json' "$FAKE_FBRain_ARGS"
grep -q -- 'put routine-heartbeats --type reference --json' "$FAKE_FBRain_ARGS"

expected="$tmp/expected"
printf 'new-heartbeat\nold-one\nold-two\n' > "$expected"
cmp "$expected" "$FAKE_FBRain_PUT_BODY"

rm -f "$FAKE_FBRain_PUT_BODY"
export FAKE_FBRain_READ_FAIL=1
if "$ROOT/bin/last-stack-fbrain-append-heartbeat" --line "must-not-write" >/dev/null 2>&1; then
  echo "expected read failure" >&2
  exit 1
fi
if [ -e "$FAKE_FBRain_PUT_BODY" ]; then
  echo "helper wrote after a read failure" >&2
  exit 1
fi

echo "ok"
