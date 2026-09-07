#!/usr/bin/env bash
# What `host-track status` REPORTS when a Forgejo gate head can and cannot be
# read. The companion to tests/host-track-forge-gate-head-auth.sh, which unit-
# tests `forge_auth_args` and proves the right `-c` words come out.
#
# This file asserts the behaviour those words exist for, because the outage had
# two halves and emitting the header only fixes the first:
#
#   1. the gate head could not be read at all (no token), and
#   2. losing the gate read was INDISTINGUISHABLE from having nothing to do.
#
# Half 2 is what made it expensive. `bin/last-stack-canary-build-main-gate`
# short-circuits on `[ -z "$gate_head" ]` and prints
# `ROUTINE_RESULT outcome=noop detail=not-stale`, so for a full day the canary
# line reported success-shaped noops while producing nothing:
# `lastdb-canary-build-main` printed `noop not-stale ... gate_head=none` hourly,
# `lastdb-canary-red-heal` answered `idle reason=listing_stale exec=` on 10
# fires out of 10 with no release execution to heal, and `lastdb-canary-dogfood`
# errored `candidate_absent behind_main=140 window=25`. Measured on the live
# host 2026-09-07: `gate_head` resolved for all 15 artifact-installed apps and
# was NULL for exactly `lastdb` and `lastdbd` — the only two on the deployment
# path, the only caller of `remote_head`.
#
# So a token that works is not the whole guard. An unreadable gate must stay a
# REPORTED PROBLEM: `deployment_problem` set, `freshness=hard_broken`, and never
# `fresh` or `stale=false`. That is asserted below, and it is the assertion that
# would have kept the canary honest even while the credential was missing.
#
# Driven through the real `last_stack_forge_token`, whose first resolution step
# is `$FORGE_TOKEN` — so the cases below need no stub of the token library, and
# they exercise the shipped resolver rather than a copy of it. `security` and
# `lastsecrets` are shadowed on PATH so the no-token case cannot fall through to
# this host's real keychain or LastDB node: a test that consults either is not
# hermetic and would answer differently on the forge runner.
#
# Papercuts: papercut-host-track-lastdb-hard-broken-when-published-head-is-unavailable-20260906,
# papercut-canary-pipeline-stall-hides-behind-five-downstream-noops
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TOKEN="s3cret-forge-token"
WANT_HEADER="Authorization: token $TOKEN"
# Must literally be a localhost:3300 base: that base is what `forge_auth_args`
# keys on, and a rewritten URL would silently take the non-forge path.
GATE_REMOTE="http://localhost:3300/EdgeVector/fold.git"

seed="$tmp/seed"; cache="$tmp/cache.git"; current="$tmp/current"
real_remote="$tmp/fold.git"
mkdir -p "$seed" "$current" "$tmp/bin" "$tmp/stamps"

/usr/bin/git init -q --bare "$real_remote"
/usr/bin/git init -q -b main "$seed"
/usr/bin/git -C "$seed" config user.name test
/usr/bin/git -C "$seed" config user.email test@example.com
printf 'one\n' > "$seed/file.txt"
/usr/bin/git -C "$seed" add file.txt
/usr/bin/git -C "$seed" commit -q -m one
installed_oid="$(/usr/bin/git -C "$seed" rev-parse HEAD)"
/usr/bin/git -C "$seed" remote add origin "$real_remote"
/usr/bin/git -C "$seed" push -q origin main
printf 'two\n' > "$seed/file.txt"
/usr/bin/git -C "$seed" commit -qam two
gate_oid="$(/usr/bin/git -C "$seed" rev-parse HEAD)"
/usr/bin/git -C "$seed" push -q origin main
/usr/bin/git clone -q --bare "$real_remote" "$cache"

# Stands in for the forge on the one subcommand the gate read uses. It answers
# `ls-remote` for the localhost:3300 remote ONLY when the scoped extraHeader
# reached its own argv, and otherwise reproduces the exact refusal a real
# unauthenticated git gives. That is what makes "the token works" an assertion
# instead of a hope. Every other git call is delegated untouched.
cat > "$tmp/bin/git" <<STUB
#!/usr/bin/env bash
want_header='$WANT_HEADER'
gate_remote='$GATE_REMOTE'
real_remote='$real_remote'
STUB
cat >> "$tmp/bin/git" <<'STUB'
is_ls_remote=""
hits_gate=""
header=""
prev=""
for arg in "$@"; do
  [ "$arg" = "ls-remote" ] && is_ls_remote=1
  [ "$arg" = "$gate_remote" ] && hits_gate=1
  case "$prev" in
    -c) case "$arg" in http.http://localhost:3300/.extraHeader=*) header="${arg#*=}" ;; esac ;;
  esac
  prev="$arg"
done
if [ -n "$is_ls_remote" ] && [ -n "$hits_gate" ]; then
  if [ "$header" != "$want_header" ]; then
    echo "fatal: could not read Username for 'http://localhost:3300': Device not configured" >&2
    exit 128
  fi
  exec /usr/bin/git ls-remote "$real_remote" refs/heads/main
fi
exec /usr/bin/git "$@"
STUB
chmod +x "$tmp/bin/git"

# Keep the no-token case off this host's keychain and node. `security` exits
# the way a locked keychain does; `lastsecrets` reports a missing secret.
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/security"
printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/bin/lastsecrets"
chmod +x "$tmp/bin/security" "$tmp/bin/lastsecrets"

write_binary() {
  local path="$1" oid="$2" name="$3"
  printf '#!/usr/bin/env bash\nprintf "%%s 0.23.3-test-g%%s\\n" %s %s\n' "$name" "$oid" > "$path"
  chmod +x "$path"
}
write_binary "$current/lastdb" "${installed_oid:0:12}" lastdb
write_binary "$current/lastdbd" "${installed_oid:0:12}" lastdbd

registry="$tmp/registry.json"
cat > "$registry" <<EOF
{
  "apps": [
    {
      "app": "lastdbd",
      "install_mode": "checkout",
      "kind": "safe-upgrade-managed binary",
      "command": "lastdbd",
      "gate": "forgejo",
      "gate_remote": "$GATE_REMOTE",
      "gate_ref": "refs/heads/main",
      "deployment_binary": "$current/lastdbd",
      "deployment_peer_binary": "$current/lastdb",
      "deployment_repo_cache": "$cache",
      "artifact_exemption": {
        "kind": "deployment-only",
        "owner": "platform",
        "rationale": "safe upgrade only"
      }
    }
  ]
}
EOF

export HOST_TRACK_REGISTRY="$registry"
export HOST_TRACK_STAMP_DIR="$tmp/stamps"

status_with_token() {
  env PATH="$tmp/bin:$PATH" FORGE_TOKEN="$1" \
    "$ROOT/bin/host-track" status --json lastdbd
}

# ── 1. a resolvable token makes the Forgejo gate head readable ──────────────
authed="$(status_with_token "$TOKEN")"
printf '%s\n' "$authed" | jq -e \
  --arg installed "$installed_oid" --arg gate "$gate_oid" '
    .host_head == $installed
    and .gate_head == $gate
    and .deployment_problem == null
    and .stale == true
    and .freshness == "soft_stale"
  ' >/dev/null || fail "an authenticated Forgejo gate did not resolve: $authed"

# ── 2. an UNREADABLE gate stays a reported problem ─────────────────────────
# The half of the outage that emitting a header does not fix. Never `fresh`,
# never `stale=false`, and the reason must survive to the caller — otherwise a
# credential fault silences the canary line again exactly as it did.
unauthed="$(status_with_token "")"
printf '%s\n' "$unauthed" | jq -e '
    .gate_head == null
    and .deployment_problem == "published gate head is unavailable"
    and .freshness == "hard_broken"
    and .stale == true
  ' >/dev/null || fail "an unreadable gate was not reported as a problem: $unauthed"

# ── 3. a REJECTED token is a failure, not a silent pass ────────────────────
# Without this, case 1 could pass because the stub felt like answering.
wrong="$(status_with_token "wrong-token")"
printf '%s\n' "$wrong" | jq -e '.gate_head == null' >/dev/null \
  || fail "a rejected token still produced a gate head: $wrong"

# ── 4. reading the gate must not paper over real lag ───────────────────────
# The opposite failure to case 2: a fix that made everything look current would
# also silence the canary, just in the other direction.
write_binary "$current/lastdb" "${gate_oid:0:12}" lastdb
write_binary "$current/lastdbd" "${gate_oid:0:12}" lastdbd
fresh="$(status_with_token "$TOKEN")"
printf '%s\n' "$fresh" | jq -e \
  --arg gate "$gate_oid" '
    .host_head == $gate
    and .gate_head == $gate
    and .behind_by == 0
    and .stale == false
    and .freshness == "fresh"
  ' >/dev/null || fail "a gate-matching deployment did not read fresh: $fresh"

printf 'ok host-track-forge-gate-head-behaviour\n'
