#!/usr/bin/env bash
# App-to-app dependencies in the Host Track registry (`requires`):
#   - validate-registry rejects unknown names, self-requires and cycles;
#   - `host-track requires` prints the transitive install order;
#   - `host-track install <app>` installs missing required apps first;
#   - `host-track check <app>` fails while a required app is absent from the host;
#   - a missing required app that host-track cannot install fails the install.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export HOME="$tmp/home"
export HOST_TRACK_REGISTRY="$tmp/registry.json"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
export HOST_TRACK_LOCK_DIR="$tmp/locks"
export HOST_TRACK_SOAK_FILE_CARD=0
export PATH="$HOME/.local/bin:$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$HOME/.local/bin" "$tmp/bin" "$tmp/cas"

# Minimal `lastgit artifact resolve`: serve the channel manifest from the fixture CAS.
cat > "$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = artifact ] && [ "${2:-}" = resolve ] || exit 2
shift 2
app="" channel="" root=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --channel) channel="$2"; shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --json) shift ;;
    *) exit 2 ;;
  esac
done
manifest="$root/channels/$app/$channel.json"
[ -f "$manifest" ] || exit 3
cat "$manifest"
SH
chmod +x "$tmp/bin/lastgit"

# app_entry <app> <requires-json>: one artifact app whose command is <app>.
app_entry() {
  jq -n --arg app "$1" --argjson requires "$2" '{
    app: $app, kind: "artifact-bundle", command: $app,
    artifact_root: "$HOME/../cas", install_root: ("$HOME/apps/" + $app),
    links: [{source: ("bin/" + $app), target: ("$HOME/.local/bin/" + $app)}],
    requires: $requires,
    safe_upgrade: {soak_hours: 1, probes: [{argv: [("bin/" + $app)]}, {argv: [("bin/" + $app), "read"]}]}
  }'
}

write_registry() {
  # write_registry <file> <entry-json>...
  local out="$1"; shift
  printf '%s\n' "$@" | jq -s '{defaults: {install_mode: "artifact", artifact_channel: "stable"}, apps: .}' > "$out"
}

publish() {
  local app="$1" n="$2" payload sha size digest
  payload="$tmp/payload-$app"
  printf '#!/usr/bin/env bash\necho %s\n' "$app" > "$payload"
  sha="$(shasum -a 256 "$payload" | awk '{print $1}')"
  size="$(wc -c < "$payload" | tr -d ' ')"
  digest="$(printf "$n%.0s" {1..64})"
  mkdir -p "$tmp/cas/blobs/sha256/${sha:0:2}" "$tmp/cas/channels/$app"
  cp "$payload" "$tmp/cas/blobs/sha256/${sha:0:2}/$sha"
  jq -n --arg app "$app" --arg digest "$digest" --arg sha "$sha" --argjson size "$size" \
    --arg oid "$(printf "$n%.0s" {1..40})" \
    '{schema_version: 1, app: $app, repo: ("EdgeVector/" + $app), source_oid: $oid,
      platform: "test-arm64", created_at: "2026-09-23T00:00:00Z",
      files: [{path: ("bin/" + $app), sha256: $sha, size: $size, mode: 493}],
      manifest_digest: $digest}' > "$tmp/cas/channels/$app/stable.json"
}

# --- lint -------------------------------------------------------------------
lint_fails() {
  local name="$1" want="$2"; shift 2
  write_registry "$tmp/$name.json" "$@"
  if HOST_TRACK_REGISTRY="$tmp/$name.json" "$ROOT/bin/host-track" validate-registry >/dev/null 2>"$tmp/$name.err"; then
    fail "validate-registry accepted $name"
  fi
  grep -q -- "$want" "$tmp/$name.err" || fail "$name: expected '$want' in: $(cat "$tmp/$name.err")"
}
lint_fails unknown 'requires unknown app: ghost' "$(app_entry kanban '["ghost"]')"
lint_fails self 'requires itself' "$(app_entry kanban '["kanban"]')"
lint_fails cycle 'requires cycle: a -> b -> a' "$(app_entry a '["b"]')" "$(app_entry b '["a"]')"
lint_fails notname 'requires entry is not an app name' "$(app_entry kanban '[7]')"

# --- the real fixture: kanban -> loom -> base; also kanban -> base ------------
write_registry "$HOST_TRACK_REGISTRY" \
  "$(app_entry kanban '["loom", "base"]')" \
  "$(app_entry loom '["base"]')" \
  "$(app_entry base '[]')"
"$ROOT/bin/host-track" validate-registry --json | jq -e '.ok and .bad_requires == 0' >/dev/null \
  || fail "acyclic registry with known names should pass validate-registry"

plan="$("$ROOT/bin/host-track" requires --json kanban || true)"
printf '%s\n' "$plan" | jq -e '.install_order == ["base", "loom"] and .missing == ["base", "loom"] and (.ok | not)' >/dev/null \
  || fail "requires did not give dependencies-first order with both missing: $plan"
if "$ROOT/bin/host-track" requires kanban >/dev/null; then
  fail "requires must exit non-zero while a required app is missing"
fi

publish base 1
publish loom 2
publish kanban 3
"$ROOT/bin/host-track" install kanban >"$tmp/install.out" 2>"$tmp/install.err" \
  || { cat "$tmp/install.err" >&2; fail "install kanban failed"; }
[ "$(base)" = base ] || fail "base was not installed"
[ "$(loom)" = loom ] || fail "loom was not installed"
[ "$(kanban)" = kanban ] || fail "kanban was not installed"
grep -q 'kanban requires base; installing base first' "$tmp/install.err" \
  || fail "install did not say it installed base first: $(cat "$tmp/install.err")"
# base appears once even though two apps require it.
[ "$(grep -c 'installing base first' "$tmp/install.err")" = 1 ] || fail "base installed more than once"
base_line="$(grep -n 'installing base first' "$tmp/install.err" | cut -d: -f1)"
loom_line="$(grep -n 'installing loom first' "$tmp/install.err" | cut -d: -f1)"
[ "$base_line" -lt "$loom_line" ] || fail "loom was installed before base"

"$ROOT/bin/host-track" requires --json kanban | jq -e '.ok and .missing == []' >/dev/null \
  || fail "requires still reports a gap after install"
"$ROOT/bin/host-track" check kanban >/dev/null || fail "check kanban failed with every dependency present"

# Remove loom from the host: check must fail and name it; reinstall heals.
mv "$HOME/.local/bin/loom" "$tmp/loom-link"
check_err="$("$ROOT/bin/host-track" check kanban 2>&1 >/dev/null || true)"
printf '%s\n' "$check_err" | grep -q 'kanban requires loom, not installed' \
  || fail "check did not name the missing required app (got: $check_err)"
mv "$tmp/loom-link" "$HOME/.local/bin/loom"
"$ROOT/bin/host-track" check kanban >/dev/null || fail "check did not pass after loom came back"

# --- a dependency host-track cannot install ----------------------------------
write_registry "$tmp/checkout-dep.json" \
  "$(app_entry kanban '["lastdbd"]')" \
  '{"app": "lastdbd", "kind": "binary", "command": "lastdbd-absent-cmd", "install_mode": "checkout",
    "artifact_exemption": {"kind": "deployment-only", "owner": "platform", "rationale": "safe upgrade owns it"}}'
if HOST_TRACK_REGISTRY="$tmp/checkout-dep.json" "$ROOT/bin/host-track" install kanban >/dev/null 2>"$tmp/checkout.err"; then
  fail "install succeeded with a missing non-artifact dependency"
fi
grep -q 'kanban requires lastdbd, which is not installed and is not an artifact app' "$tmp/checkout.err" \
  || fail "missing non-artifact dependency error unclear: $(cat "$tmp/checkout.err")"

# --- an unknown dependency stops install before any work ---------------------
write_registry "$tmp/unknown-install.json" "$(app_entry kanban '["ghost"]')"
if HOST_TRACK_REGISTRY="$tmp/unknown-install.json" "$ROOT/bin/host-track" install kanban >/dev/null 2>"$tmp/unknown-install.err"; then
  fail "install succeeded with an unknown required app"
fi
grep -q 'unknown required app: ghost' "$tmp/unknown-install.err" \
  || fail "unknown dependency error unclear: $(cat "$tmp/unknown-install.err")"

# --- the shipped registries --------------------------------------------------
HOST_TRACK_REGISTRY="$ROOT/config/host-track/apps.json" "$ROOT/bin/host-track" validate-registry --json \
  | jq -e '.bad_requires == 0' >/dev/null || fail "shipped host-track registry has bad requires"
# The public bundle has no validate-registry: every edge must name a bundle app.
bad_public="$(jq -r '((.apps // {}) + (.brew_apps // {})) as $a | $a | to_entries[] | .key as $app
  | ((.value.requires // []) + (.value.recommends // []))[]
  | select(. as $d | $a | has($d) | not) | "\($app) -> \(.)"' "$ROOT/config/registry/apps.json")"
[ -z "$bad_public" ] || fail "public registry names apps outside the bundle: $bad_public"

# --- last-stack-install-apps reports an unmet requirement --------------------
mkdir -p "$tmp/ls/bin" "$tmp/ls/config/registry"
cp "$ROOT/bin/last-stack-install-apps" "$tmp/ls/bin/"
jq -n '{apps: {kanban: {requires: ["loom-not-in-bundle"]}, brain: {requires: ["situations"]}}}' \
  > "$tmp/ls/config/registry/apps.json"
# Run only the report function: source the definition, not the whole installer.
sed -n '/^report_unmet_requires() {/,/^}/p' "$tmp/ls/bin/last-stack-install-apps" > "$tmp/report.sh"
[ -s "$tmp/report.sh" ] || fail "report_unmet_requires not found in last-stack-install-apps"
# shellcheck disable=SC1091
. "$tmp/report.sh"
warn="$(report_unmet_requires "$tmp/ls/config/registry/apps.json" '["brain","kanban","situations"]' 2>&1)"
printf '%s\n' "$warn" | grep -q 'WARNING: kanban requires loom-not-in-bundle' \
  || fail "installer did not warn on a requirement outside the bundle (got: $warn)"
printf '%s\n' "$warn" | grep -q 'brain requires' && fail "installer warned on a requirement the bundle installs"

echo "ok host-track requires"
