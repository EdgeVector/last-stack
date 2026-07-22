#!/usr/bin/env bash
# One rule: artifact runtime never falls through to git self-upgrade / dirty heal.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export HOME="$tmp/home"
export PATH="$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
# Live install path (self-upgrade only refuses git heal for this root).
compat="$HOME/.last-stack"
mkdir -p "$tmp/bin" "$compat/routines" "$compat/bin" "$compat/.artifacts/current/bin"

# Fake host-track: always artifact + fresh.
cat > "$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  status)
    jq -n '{app:"last-stack",install_mode:"artifact",stale:false,
      manifest_digest:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      channel_manifest_digest:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
    ;;
  check) exit 0 ;;
  refresh) exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/host-track"

# Install scripts under the live compat root (as production does after layout).
cp "$ROOT/bin/last-stack-routine-read" "$compat/bin/"
cp "$ROOT/bin/last-stack-self-upgrade" "$compat/bin/"
cp "$ROOT/bin/last-stack-update-check" "$compat/bin/"
chmod +x "$compat/bin/"*
printf '%s\n' '---' 'name: kanban-watch' '---' 'card_batch_limit: 1' > "$compat/routines/kanban-watch.md"
# Mark layout active the way production does.
rm -rf "$compat/bin"
ln -s "$compat/.artifacts/current/bin" "$compat/bin"
mkdir -p "$compat/.artifacts/current/bin" "$compat/.artifacts/current/routines"
cp "$ROOT/bin/last-stack-routine-read" "$compat/.artifacts/current/bin/"
cp "$ROOT/bin/last-stack-self-upgrade" "$compat/.artifacts/current/bin/"
cp "$ROOT/bin/last-stack-update-check" "$compat/.artifacts/current/bin/"
chmod +x "$compat/.artifacts/current/bin/"*
printf '%s\n' '---' 'name: kanban-watch' '---' 'card_batch_limit: 1' \
  > "$compat/.artifacts/current/routines/kanban-watch.md"

# Self-upgrade against live install must refuse git path and point at host-track.
out="$("$compat/bin/last-stack-self-upgrade" 2>"$tmp/err" || true)"
printf '%s\n' "$out" | grep -q 'result=artifact-runtime' || fail "self-upgrade did not report artifact-runtime: $out"
grep -q 'host-track refresh last-stack' "$tmp/err" || fail "self-upgrade stderr missing host-track remediation"

# routine-read must serve the prompt without invoking git self-upgrade.
# Force a broken self-upgrade so any fall-through fails loudly.
cat > "$compat/.artifacts/current/bin/last-stack-self-upgrade" <<'SH'
#!/usr/bin/env bash
echo "LAST_STACK_SELF_UPGRADE result=error-dirty should-not-run" >&2
exit 1
SH
chmod +x "$compat/.artifacts/current/bin/last-stack-self-upgrade"

prompt="$("$compat/bin/last-stack-routine-read" kanban-watch)"
printf '%s\n' "$prompt" | grep -q 'card_batch_limit' || fail "routine-read did not return prompt under artifact mode"

printf 'ok: artifact one-rule (no git self-upgrade fall-through)\n'
