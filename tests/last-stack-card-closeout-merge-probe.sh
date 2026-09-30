#!/usr/bin/env bash
# Pin the Forgejo (*/pulls/*) and GitHub (*/pull/*) branches of the merge probe.
#
# Regression: the probe called `last-stack-forge-api --jq -r '.merged' <path>`.
# The wrapper accepts exactly ONE argument after --jq, so it consumed `-r` as
# the filter and rejected the real path with "unexpected extra argument"
# (exit 2). The call also swallowed stderr and fell back to `|| true`, so every
# Forgejo PR read as unmerged and the merged-PR -> done closeout path silently
# broke for days.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-card-closeout-merge-probe"

bash -n "$bin"
chmod +x "$bin" 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-probe-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

argv_log="$tmp/argv"
stub="$tmp/forge-api"

# Stub stands in for last-stack-forge-api. It enforces the real wrapper's
# contract: exactly one argument after --jq, then exactly one path.
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${ARGV_LOG:?}"
filter=
path=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq)
      filter="$2"
      shift 2
      ;;
    -*)
      echo "unexpected flag: $1" >&2
      exit 2
      ;;
    *)
      if [ -n "$path" ]; then
        echo "unexpected extra argument: $1" >&2
        exit 2
      fi
      path="$1"
      shift
      ;;
  esac
done
if [ "$filter" != ".merged" ]; then
  echo "unexpected filter: $filter" >&2
  exit 2
fi
case "$path" in
  */pulls/1047) echo true ;;
  */pulls/1722) echo false ;;
  *) echo "unknown pull: $path" >&2; exit 2 ;;
esac
STUB
chmod +x "$stub"

base="http://forge.invalid:3300/EdgeVector/fold/pulls"

# 1. A merged PR exits 0.
if ! ARGV_LOG="$argv_log" LAST_STACK_FORGE_API="$stub" "$bin" "$base/1047"; then
  echo "expected merged PR 1047 to probe as merged" >&2
  exit 1
fi

# The exact argv is the regression: --jq, the filter, then the path. A bare -r
# reappearing here is the original bug.
if ! grep -qx -- "--jq .merged repos/EdgeVector/fold/pulls/1047" "$argv_log"; then
  echo "probe passed the wrong argv to forge-api:" >&2
  cat "$argv_log" >&2
  exit 1
fi
if grep -q -- "--jq -r" "$argv_log"; then
  echo "probe reintroduced the '--jq -r' misuse" >&2
  exit 1
fi

# 2. An open PR exits nonzero (no false positive).
if ARGV_LOG="$argv_log" LAST_STACK_FORGE_API="$stub" "$bin" "$base/1722"; then
  echo "expected open PR 1722 to probe as unmerged" >&2
  exit 1
fi

# 3. A failing API call must not masquerade as "not merged" -- it must say so.
failing="$tmp/forge-api-fail"
cat >"$failing" <<'STUB'
#!/usr/bin/env bash
echo "unexpected extra argument: whatever" >&2
exit 2
STUB
chmod +x "$failing"

err="$tmp/err"
if LAST_STACK_FORGE_API="$failing" "$bin" "$base/1047" 2>"$err"; then
  echo "expected a failing forge API call to probe as not-merged" >&2
  exit 1
fi
if ! grep -q "forge API query failed" "$err"; then
  echo "a broken probe call was reported silently:" >&2
  cat "$err" >&2
  exit 1
fi

# 4. A missing forge-api binary is reported, not silently unmerged.
if LAST_STACK_FORGE_API="$tmp/does-not-exist" "$bin" "$base/1047" 2>"$err"; then
  echo "expected missing forge-api to fail the probe" >&2
  exit 1
fi
grep -q "last-stack-forge-api missing" "$err"

# 5. GitHub URLs go through `gh` (PATH stub). Merged -> 0, open -> 1, gh
# failure -> 1 with a message, lastgit CR URL -> 1 with a retired message.
ghbin="$tmp/ghbin"
mkdir -p "$ghbin"
cat >"$ghbin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_LOG:?}"
case "$*" in
  *"pr view 10 "*) echo '{"state":"MERGED","mergedAt":"2026-09-30T00:00:00Z"}' ;;
  *"pr view 11 "*) echo '{"state":"OPEN","mergedAt":null}' ;;
  *) echo "gh: not found" >&2; exit 1 ;;
esac
STUB
chmod +x "$ghbin/gh"
gh_url="https://github.com/EdgeVector/last-stack/pull"
export GH_LOG="$tmp/gh.log"
PATH="$ghbin:$PATH" "$bin" "$gh_url/10"
grep -q -- "-R EdgeVector/last-stack pr view 10" "$GH_LOG"
if PATH="$ghbin:$PATH" "$bin" "$gh_url/11"; then
  echo "expected open GitHub PR to probe as unmerged" >&2; exit 1
fi
if PATH="$ghbin:$PATH" "$bin" "$gh_url/12" 2>"$err"; then
  echo "expected failing gh to probe as not-merged" >&2; exit 1
fi
grep -q "gh query failed" "$err"
if "$bin" "lastgit://last-stack/cr/cr-abc-1234" 2>"$err"; then
  echo "expected a lastgit CR URL to fail the probe" >&2; exit 1
fi
grep -q "retired" "$err"

echo "ok last-stack-card-closeout-merge-probe"
