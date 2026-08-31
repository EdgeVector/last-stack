#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/observer-why-loom.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/root/bin" "$tmp/home/.last-stack/bin"
cp "$ROOT/bin/last-stack-routine-observer-gate" "$tmp/root/bin/"
grep -q 'LAST_STACK_WHY_STOPPED_LOOM_TIMEOUT_SEC:-600' "$tmp/root/bin/last-stack-routine-observer-gate" || {
  echo "why-stopped Loom timeout is not a bounded ten-minute default" >&2
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

# rc 4: loom classified the freeze but could not finish its execution. The
# classification is real, so the observer stays green — and the detail must
# say `incomplete`, not `unavailable`. Reporting the two the same way sent
# readers looking for a missing binary while loom was up and answering.
cat >"$tmp/home/.last-stack/bin/last-stack-why-stopped-loom" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"classes":"D+F","engine":"loom"}'
exit 4
SH
chmod 755 "$tmp/home/.last-stack/bin/last-stack-why-stopped-loom"
out="$(HOME="$tmp/home" PATH="/usr/bin:/bin" "$tmp/root/bin/last-stack-routine-observer-gate" last-stack-why-stopped)"
printf '%s\n' "$out" | grep -q -- '--exit 0' || {
  echo "incomplete Loom path with a real classification must stay green: $out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -q 'classes=D+F' || {
  echo "incomplete Loom path lost its classes: $out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -q 'loom=incomplete' || {
  echo "incomplete Loom path did not say incomplete: $out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -q 'loom=unavailable' && {
  echo "incomplete Loom path still reports unavailable: $out" >&2
  exit 1
}

# rc 4 with nothing to classify falls back, and still must not claim the
# binary is missing.
cat >"$tmp/home/.last-stack/bin/last-stack-why-stopped-loom" <<'SH'
#!/usr/bin/env bash
exit 4
SH
chmod 755 "$tmp/home/.last-stack/bin/last-stack-why-stopped-loom"
out="$(HOME="$tmp/home" PATH="/usr/bin:/bin" "$tmp/root/bin/last-stack-routine-observer-gate" last-stack-why-stopped)"
printf '%s\n' "$out" | grep -q 'loom=incomplete rc=4' || {
  echo "blank incomplete Loom path lost its cause: $out" >&2
  exit 1
}

echo ok
