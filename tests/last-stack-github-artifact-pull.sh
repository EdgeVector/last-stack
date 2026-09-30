#!/usr/bin/env bash
# GitHub artifact publish path: builder (runner side) and puller (Mac side),
# fixture-only. The cases are in last-stack-github-artifact-pull.py.
# Brain: design-github-artifact-publish-path
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
chmod +x "$ROOT"/tests/fixtures/github-artifact/fake-gh "$ROOT"/tests/fixtures/github-artifact/fake-lastgit 2>/dev/null || true
export PYTHONDONTWRITEBYTECODE=1 PYTHONWARNINGS=ignore
python3 "$ROOT/tests/last-stack-github-artifact-pull.py"
echo "ok last-stack-github-artifact-pull"
