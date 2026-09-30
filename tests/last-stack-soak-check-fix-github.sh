#!/usr/bin/env bash
# loom-soak-check-fix.sh reads the app repo tip and its ci-required check run
# from GitHub (gh stub on PATH). LastGit is retired: no lastgit call.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CHECK="$ROOT/lib/soak-loom/loom-soak-check-fix.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/soak-check-gh.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >>"${GH_LOG:?}"
case "$2" in
  repos/EdgeVector/fkanban/git/ref/heads/main) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
  repos/EdgeVector/fkanban/commits/*/check-runs*) echo "${CI_STATE:-success}" ;;
  *) exit 1 ;;
esac
SH
cat >"$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
echo "lastgit must not be called" >&2; exit 97
SH
chmod +x "$tmp/bin/gh" "$tmp/bin/lastgit"
run() { env PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" LOOM_LIVE=1 LOOM_INPUT='{"app":"kanban"}' "$@" "$CHECK"; }
: >"$tmp/gh.log"
# The stub prints what --jq would print; the check must accept only `success`.
run CI_STATE=success || fail "green tip must pass"
grep -q 'repos/EdgeVector/fkanban/git/ref/heads/main' "$tmp/gh.log" || fail "kanban must map to fkanban: $(cat "$tmp/gh.log")"
grep -q 'check_name=ci-required' "$tmp/gh.log" || fail "must read the ci-required check run"
if run CI_STATE=other; then fail "a non-success tip must not pass"; fi
# Offline stand-in still accepts without any network read.
env PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh2.log" LOOM_INPUT='{"app":"kanban"}' "$CHECK" || fail "stand-in must accept"
[ ! -e "$tmp/gh2.log" ] || fail "stand-in made a gh call"
echo "PASS last-stack-soak-check-fix-github"
