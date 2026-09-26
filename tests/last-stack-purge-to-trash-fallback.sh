#!/usr/bin/env bash
# Test: emergency purge falls back to direct delete when Trash is unavailable.
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
HELPER="$ROOT/bin/last-stack-purge-to-trash"
chmod +x "$HELPER"

# Use a tmp directory as HOME to avoid touching real Trash
tmp="$(mktemp -d "${TMPDIR:-/tmp}/purge-to-trash-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

export HOME="$tmp"

# Test 1: Fallback delete when Trash unavailable
echo "Test 1: Fallback delete when Trash unavailable..."
{
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin"  # Use standard tools, no homebrew

  mkdir -p "$tmp/mock"
  cat >"$tmp/mock/trash" <<'SH'
#!/bin/bash
echo "Error: Permission denied" >&2
exit 1
SH
  chmod +x "$tmp/mock/trash"

  cat >"$tmp/mock/gio" <<'SH'
#!/bin/bash
if [ "$1" = "trash" ]; then
  echo "Error: Cannot create Trash directory" >&2
  exit 1
fi
exit 1
SH
  chmod +x "$tmp/mock/gio"

  export PATH="$tmp/mock:$PATH"

  # Create cache dir to purge
  cache_dir="$tmp/build-cache.PURGE"
  mkdir -p "$cache_dir/target/debug"
  echo "test" >"$cache_dir/target/debug/binary"

  log_file="$tmp/purge.log"

  # Run helper - expect exit 1 (fallback delete)
  set +e
  "$HELPER" --log-file "$log_file" "$cache_dir"
  result=$?
  set -e

  if [ $result -ne 1 ]; then
    echo "FAIL: Expected exit code 1, got $result" >&2
    exit 1
  fi

  if [ -d "$cache_dir" ]; then
    echo "FAIL: Directory was not deleted" >&2
    exit 1
  fi

  if ! grep -q "trash_unavailable_fallback_to_delete" "$log_file"; then
    echo "FAIL: Log missing 'trash_unavailable_fallback_to_delete'" >&2
    cat "$log_file" >&2
    exit 1
  fi

  if ! grep -q "fallback_delete_succeeded" "$log_file"; then
    echo "FAIL: Log missing 'fallback_delete_succeeded'" >&2
    cat "$log_file" >&2
    exit 1
  fi

  echo "PASS: Fallback delete works with mocked Trash failures"
}

# Test 2: Success case when Trash is available
echo ""
echo "Test 2: Success case when real Trash is available..."
{
  # Create a fresh cache dir
  cache_dir2="$tmp/build-cache2.PURGE"
  mkdir -p "$cache_dir2/target"
  echo "test" >"$cache_dir2/target/file"

  log_file2="$tmp/purge2.log"

  # Reset PATH to use real commands
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

  set +e
  "$HELPER" --log-file "$log_file2" "$cache_dir2"
  result=$?
  set -e

  if [ ! -d "$cache_dir2" ]; then
    echo "PASS: Directory was removed (exit code $result)"
  else
    echo "FAIL: Directory was not removed" >&2
    exit 1
  fi

  # If Trash CLI is available, verify that Trash was actually used (exit 0)
  if command -v trash >/dev/null 2>&1 || command -v gio >/dev/null 2>&1; then
    # When Trash CLI is available, we must verify it was used
    if grep -q "moved_to_trash method=" "$log_file2"; then
      if [ "$result" -eq 0 ]; then
        echo "PASS: Trash was used successfully (exit 0, verified in log)"
      else
        echo "FAIL: Log shows Trash was used but exit code was $result, expected 0" >&2
        cat "$log_file2" >&2
        exit 1
      fi
    else
      # Trash CLI is available but wasn't used - this is a regression
      echo "FAIL: Trash CLI available but was not used (log does not show 'moved_to_trash method=')" >&2
      cat "$log_file2" >&2
      exit 1
    fi
  else
    # Trash CLI is unavailable on this system, only accept fallback exit 1
    if [ "$result" -eq 1 ]; then
      echo "PASS: Trash unavailable on this system, fell back to delete (exit 1)"
    else
      echo "FAIL: No Trash CLI available, expected fallback (exit 1), got $result" >&2
      exit 1
    fi
  fi
}

# Test 3: Error case - non-existent path
echo ""
echo "Test 3: Error case - non-existent path..."
{
  set +e
  "$HELPER" /nonexistent/path >/dev/null 2>&1
  result=$?
  set -e

  if [ $result -eq 3 ]; then
    echo "PASS: Correct exit code 3 for non-existent path"
  else
    echo "FAIL: Expected exit code 3, got $result" >&2
    exit 1
  fi
}

echo ""
echo "ok last-stack-purge-to-trash-fallback"
