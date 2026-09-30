#!/usr/bin/env bash
# A generic `papercut-pipeline-stuck-pr-<repo>-<n>` slug names a LIVE PR. Since
# 2026-09-30 every EdgeVector repo except lastgit is on GitHub, so for a moved
# repo the ref is a GitHub PR, not a Forgejo one. An explicit Forgejo ref
# (`stuck-forge` slug) still resolves on the archived Forgejo copy. Fixture only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-gh-venue.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/check.py" <<'PY'
import importlib.machinery, importlib.util, os, sys

root = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("closer", os.path.join(root, "bin", "last-stack-papercut-lifecycle-close"))
spec = importlib.util.spec_from_loader("closer", loader)
mod = importlib.util.module_from_spec(spec)
sys.modules["closer"] = mod
loader.exec_module(mod)

def refs(slug, body):
    out, _skips = mod.review_refs(body, slug)
    return sorted((r.kind, r.url) for r in out)

# Moved repo, generic slug: GitHub.
got = refs("papercut-pipeline-stuck-pr-fold-1902", "Status: OPEN\nRepo: EdgeVector/fold\n")
assert got == [("github", "https://github.com/EdgeVector/fold/pull/1902")], got
# Moved repo, no Repo header: still GitHub (the repo is on the GitHub list).
got = refs("papercut-pipeline-stuck-pr-loom-12", "Status: OPEN\n")
assert got == [("github", "https://github.com/EdgeVector/loom/pull/12")], got
# lastgit stays Forgejo.
got = refs("papercut-pipeline-stuck-pr-lastgit-90", "Status: OPEN\n")
assert got == [("forge", "EdgeVector/lastgit/pulls/90")], got
# An explicit Forgejo slug for a moved repo still resolves on the archived copy.
got = refs("papercut-pipeline-stuck-forge-fold-pr-826", "Status: OPEN\nRepo: EdgeVector/fold\nPR: Forgejo #826\n")
assert ("forge", "EdgeVector/fold/pulls/826") in got, got
# An unknown repo with no header is not guessed.
got = refs("papercut-pipeline-stuck-pr-mystery-service-7", "Status: OPEN\n")
assert got == [], got
print("ok")
PY
out="$(python3 "$tmp/check.py" "$ROOT")"
[ "$out" = ok ] || { echo "FAIL: $out" >&2; exit 1; }
echo "ok last-stack-papercut-lifecycle-close-github-venue"
