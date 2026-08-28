#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/observer-why-loom.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/root/bin" "$tmp/home/.last-stack/bin"
cp "$ROOT/bin/last-stack-routine-observer-gate" "$tmp/root/bin/"
grep -q 'LAST_STACK_WHY_STOPPED_LOOM_TIMEOUT_SEC:-300' "$tmp/root/bin/last-stack-routine-observer-gate" || {
  echo "why-stopped Loom timeout is not a bounded five-minute default" >&2
  exit 1
}

cat >"$tmp/root/bin/last-stack-routine-outcome-classify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*"
SH
cat >"$tmp/root/bin/last-stack-why-stopped" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"classes":"A+D"}'
SH
cat >"$tmp/home/.last-stack/bin/last-stack-why-stopped-loom" <<'SH'
#!/usr/bin/env bash
exit 3
SH
chmod 755 "$tmp/root/bin/"* "$tmp/home/.last-stack/bin/last-stack-why-stopped-loom"

out="$(HOME="$tmp/home" PATH="/usr/bin:/bin" "$tmp/root/bin/last-stack-routine-observer-gate" last-stack-why-stopped)"
printf '%s\n' "$out" | grep -q -- '--exit 1' || {
  echo "failed Loom path did not set observer exit=1: $out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -q 'loom=unavailable rc=3' || {
  echo "failed Loom path lost its cause: $out" >&2
  exit 1
}

cat >"$tmp/home/.last-stack/bin/last-stack-why-stopped-loom" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"classes":"B","engine":"loom"}'
SH
chmod 755 "$tmp/home/.last-stack/bin/last-stack-why-stopped-loom"
out="$(HOME="$tmp/home" PATH="/usr/bin:/bin" "$tmp/root/bin/last-stack-routine-observer-gate" last-stack-why-stopped)"
printf '%s\n' "$out" | grep -q -- '--exit 0' || {
  echo "successful Loom path did not keep observer exit=0: $out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -q -- '--detail classes=B' || {
  echo "successful Loom path lost its classes: $out" >&2
  exit 1
}

echo ok
