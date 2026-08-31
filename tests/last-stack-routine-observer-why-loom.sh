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

# --- an rc=3 must name WHICH precondition failed -------------------------
# The wrapper exits 3 from eight distinct places. Every one of them used to
# reach the fleet as the bare word `unavailable`: the gate ran the wrapper
# with --quiet and 2>/dev/null, so a missing binary and a publish that could
# not reach the node were the same string. Twelve hours of red runs named no
# cause. The cause now travels on stdout, and the wrapper's own words are
# replayed onto the gate's stderr, which routines keeps as stderr.log.
cat >"$tmp/home/.last-stack/bin/last-stack-why-stopped-loom" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"loom":"unavailable","reason":"loom_publish_why_stopped_failed"}'
printf 'why-stopped-loom: loom publish why-stopped failed\n' >&2
exit 3
SH
chmod 755 "$tmp/home/.last-stack/bin/last-stack-why-stopped-loom"
out="$(HOME="$tmp/home" PATH="/usr/bin:/bin" "$tmp/root/bin/last-stack-routine-observer-gate" last-stack-why-stopped 2>"$tmp/gate.err")"
printf '%s\n' "$out" | grep -q 'cause=loom_publish_why_stopped_failed' || {
  echo "rc=3 did not name its cause: $out" >&2
  exit 1
}
grep -q 'observer-gate: why-stopped-loom: loom publish why-stopped failed' "$tmp/gate.err" || {
  echo "gate discarded the wrapper stderr: $(cat "$tmp/gate.err")" >&2
  exit 1
}

# With a run dir, the wrapper's words are also kept beside the run, where a
# later reader looks first.
mkdir -p "$tmp/rundir"
out="$(HOME="$tmp/home" PATH="/usr/bin:/bin" ROUTINES_RUN_DIR="$tmp/rundir" \
  "$tmp/root/bin/last-stack-routine-observer-gate" last-stack-why-stopped 2>/dev/null)"
grep -q 'loom publish why-stopped failed' "$tmp/rundir/why-stopped-loom.err" || {
  echo "run dir kept no wrapper stderr: $(ls "$tmp/rundir")" >&2
  exit 1
}

# A wrapper too old to print the reason still gets a cause, read back from the
# stderr the gate now keeps. Without this the fix would only work for branches
# somebody remembered to update.
cat >"$tmp/home/.last-stack/bin/last-stack-why-stopped-loom" <<'SH'
#!/usr/bin/env bash
printf 'why-stopped-loom: loom ping failed\n' >&2
exit 3
SH
chmod 755 "$tmp/home/.last-stack/bin/last-stack-why-stopped-loom"
out="$(HOME="$tmp/home" PATH="/usr/bin:/bin" "$tmp/root/bin/last-stack-routine-observer-gate" last-stack-why-stopped 2>/dev/null)"
printf '%s\n' "$out" | grep -q 'cause=loom_ping_failed' || {
  echo "stderr fallback did not recover the cause: $out" >&2
  exit 1
}

# A killed wrapper is not an unavailable one. rc=124 is the gate's own timeout.
cat >"$tmp/home/.last-stack/bin/last-stack-why-stopped-loom" <<'SH'
#!/usr/bin/env bash
exit 124
SH
chmod 755 "$tmp/home/.last-stack/bin/last-stack-why-stopped-loom"
out="$(HOME="$tmp/home" PATH="/usr/bin:/bin" "$tmp/root/bin/last-stack-routine-observer-gate" last-stack-why-stopped 2>/dev/null)"
printf '%s\n' "$out" | grep -q 'loom=timeout rc=124' || {
  echo "a timed-out wrapper still reports unavailable: $out" >&2
  exit 1
}
printf '%s\n' "$out" | grep -q 'cause=gate_timeout_' || {
  echo "timeout path did not name the bound it hit: $out" >&2
  exit 1
}

# The healthy path must stay clean: a green run carries no cause= at all.
cat >"$tmp/home/.last-stack/bin/last-stack-why-stopped-loom" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"classes":"none","engine":"loom"}'
SH
chmod 755 "$tmp/home/.last-stack/bin/last-stack-why-stopped-loom"
out="$(HOME="$tmp/home" PATH="/usr/bin:/bin" "$tmp/root/bin/last-stack-routine-observer-gate" last-stack-why-stopped 2>/dev/null)"
printf '%s\n' "$out" | grep -q 'cause=' && {
  echo "a green run must not carry a failure cause: $out" >&2
  exit 1
}

echo ok
