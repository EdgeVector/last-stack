#!/usr/bin/env python3
"""Tests for cloud-sync resume proof provenance validation."""

import json
import sys
import tempfile
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))
import check_contract


def test_evidence_without_provenance_fails():
    """Evidence without provenance section should FAIL."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        evidence = {
            "schema": "lastdb-cloud-sync-resume-proof.v1",
            "surface": {
                "kind": "ephemeral",
                "primary_home_opened": False,
                "primary_mutated": False,
                "primary_reenabled_by_harness": False,
                "live_cutover": False,
                "home_path": "/tmp/ephemeral"
            },
            "hash_group": {
                "cow_document_count": 1,
                "group_file_count": 1,
                "group_bytes_uploaded": 4096,
                "staging_object_count": 0,
                "cow_proof_verdict": "PASS",
                "promoted": False,
                "source_unchanged": True
            },
            "probe": {
                "upload_bytes": 8192,
                "upload_window_secs": 60,
                "staging_growth_bytes": 4096,
                "backlog_start": 10000,
                "backlog_end": 5000,
                "degraded": False,
                "window_start": "2026-09-26T11:00:00Z",
                "window_end": "2026-09-26T11:01:00Z"
            },
            "reenable": {
                "situation_slug": "cloud-sync-paused-pending-laststore-redesign-20260719",
                "cleared_by": "Tom",
                "reenable_actor": "Tom",
                "situation_cleared_at": "2026-09-26T10:00:00Z",
                "reenable_at": "2026-09-26T10:30:00Z"
            },
            "catchup": {
                "primary_sync_lag_bytes": 0,
                "staging_depth": 5000,
                "staging_cap": 10000,
                "brain_reads": 5,
                "brain_writes": 3,
                "kanban_reads": 4,
                "kanban_writes": 2,
                "lastgit_reads": 3,
                "lastgit_writes": 1
            },
            "file_blob": {
                "upload_bytes": 2048,
                "fetch_bytes": 2048,
                "upload_route": "upload_file_blob",
                "fetch_route": "download_file_blob",
                "canary_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            }
        }
        json.dump(evidence, f)
        evidence_path = f.name

    failures = check_contract.evidence_failures(Path(evidence_path))
    assert failures, "Evidence without provenance should have failures"
    assert any("provenance" in f for f in failures), \
        f"Expected provenance error, got: {failures}"
    Path(evidence_path).unlink()
    print("✓ test_evidence_without_provenance_fails")


def test_evidence_with_invalid_log_hash_fails():
    """Evidence with invalid log hash should FAIL."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        evidence = {
            "schema": "lastdb-cloud-sync-resume-proof.v1",
            "provenance": {
                "command": "measure.sh",
                "run_start_at": "2026-09-26T11:00:00Z",
                "run_end_at": "2026-09-26T11:01:30Z",
                "ephemeral_home_path": "/tmp/ephemeral",
                "run_log_sha256": "0000000000000000000000000000000000000000000000000000000000000000"
            },
            "surface": {
                "kind": "ephemeral",
                "primary_home_opened": False,
                "primary_mutated": False,
                "primary_reenabled_by_harness": False,
                "live_cutover": False,
                "home_path": "/tmp/ephemeral"
            },
            "hash_group": {
                "cow_document_count": 1,
                "group_file_count": 1,
                "group_bytes_uploaded": 4096,
                "staging_object_count": 0,
                "cow_proof_verdict": "PASS",
                "promoted": False,
                "source_unchanged": True
            },
            "probe": {
                "upload_bytes": 8192,
                "upload_window_secs": 60,
                "staging_growth_bytes": 4096,
                "backlog_start": 10000,
                "backlog_end": 5000,
                "degraded": False,
                "window_start": "2026-09-26T11:00:00Z",
                "window_end": "2026-09-26T11:01:00Z"
            },
            "reenable": {
                "situation_slug": "cloud-sync-paused-pending-laststore-redesign-20260719",
                "cleared_by": "Tom",
                "reenable_actor": "Tom",
                "situation_cleared_at": "2026-09-26T10:00:00Z",
                "reenable_at": "2026-09-26T10:30:00Z"
            },
            "catchup": {
                "primary_sync_lag_bytes": 0,
                "staging_depth": 5000,
                "staging_cap": 10000,
                "brain_reads": 5,
                "brain_writes": 3,
                "kanban_reads": 4,
                "kanban_writes": 2,
                "lastgit_reads": 3,
                "lastgit_writes": 1
            },
            "file_blob": {
                "upload_bytes": 2048,
                "fetch_bytes": 2048,
                "upload_route": "upload_file_blob",
                "fetch_route": "download_file_blob",
                "canary_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            }
        }
        json.dump(evidence, f)
        evidence_path = f.name

    # Create a log file with a different hash
    with tempfile.NamedTemporaryFile(mode='w', suffix='.log', delete=False) as f:
        f.write("test log content\n")
        log_path = f.name

    failures = check_contract.evidence_failures(Path(evidence_path), log_path)
    assert failures, "Evidence with mismatched log hash should have failures"
    assert any("hash does not match" in f for f in failures), \
        f"Expected hash mismatch error, got: {failures}"

    Path(evidence_path).unlink()
    Path(log_path).unlink()
    print("✓ test_evidence_with_invalid_log_hash_fails")


def test_evidence_with_matching_log_passes():
    """Evidence with matching log hash should PASS source contract."""
    # Create log file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.log', delete=False) as f:
        f.write("Measurement log\n")
        log_path = f.name

    # Compute its hash
    import hashlib
    with open(log_path, 'rb') as f:
        log_hash = hashlib.sha256(f.read()).hexdigest()

    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        evidence = {
            "schema": "lastdb-cloud-sync-resume-proof.v1",
            "provenance": {
                "command": "measure.sh",
                "run_start_at": "2026-09-26T11:00:00Z",
                "run_end_at": "2026-09-26T11:01:30Z",
                "ephemeral_home_path": "/tmp/ephemeral",
                "run_log_sha256": log_hash
            },
            "surface": {
                "kind": "ephemeral",
                "primary_home_opened": False,
                "primary_mutated": False,
                "primary_reenabled_by_harness": False,
                "live_cutover": False,
                "home_path": "/tmp/ephemeral"
            },
            "hash_group": {
                "cow_document_count": 1,
                "group_file_count": 1,
                "group_bytes_uploaded": 4096,
                "staging_object_count": 0,
                "cow_proof_verdict": "PASS",
                "promoted": False,
                "source_unchanged": True
            },
            "probe": {
                "upload_bytes": 8192,
                "upload_window_secs": 60,
                "staging_growth_bytes": 4096,
                "backlog_start": 10000,
                "backlog_end": 5000,
                "degraded": False,
                "window_start": "2026-09-26T11:00:00Z",
                "window_end": "2026-09-26T11:01:00Z"
            },
            "reenable": {
                "situation_slug": "cloud-sync-paused-pending-laststore-redesign-20260719",
                "cleared_by": "Tom",
                "reenable_actor": "Tom",
                "situation_cleared_at": "2026-09-26T10:00:00Z",
                "reenable_at": "2026-09-26T10:30:00Z"
            },
            "catchup": {
                "primary_sync_lag_bytes": 0,
                "staging_depth": 5000,
                "staging_cap": 10000,
                "brain_reads": 5,
                "brain_writes": 3,
                "kanban_reads": 4,
                "kanban_writes": 2,
                "lastgit_reads": 3,
                "lastgit_writes": 1
            },
            "file_blob": {
                "upload_bytes": 2048,
                "fetch_bytes": 2048,
                "upload_route": "upload_file_blob",
                "fetch_route": "download_file_blob",
                "canary_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            }
        }
        json.dump(evidence, f)
        evidence_path = f.name

    failures = check_contract.evidence_failures(Path(evidence_path), log_path)
    # Should have no provenance failures (but may have other failures)
    provenance_failures = [f for f in failures if "provenance" in f or "hash" in f]
    assert not provenance_failures, \
        f"Evidence with matching log hash should have no provenance failures, got: {provenance_failures}"

    Path(evidence_path).unlink()
    Path(log_path).unlink()
    print("✓ test_evidence_with_matching_log_passes")


def test_evidence_with_log_hash_but_no_log_file_fails():
    """Evidence with log hash but no log file should FAIL."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        evidence = {
            "schema": "lastdb-cloud-sync-resume-proof.v1",
            "provenance": {
                "command": "measure.sh",
                "run_start_at": "2026-09-26T11:00:00Z",
                "run_end_at": "2026-09-26T11:01:30Z",
                "ephemeral_home_path": "/tmp/ephemeral",
                "run_log_sha256": "367df19f0458c592feead82a0a52171492a942c486b1715f88c39bf6fb0e352d"
            },
            "surface": {
                "kind": "ephemeral",
                "primary_home_opened": False,
                "primary_mutated": False,
                "primary_reenabled_by_harness": False,
                "live_cutover": False,
                "home_path": "/tmp/ephemeral"
            },
            "hash_group": {
                "cow_document_count": 1,
                "group_file_count": 1,
                "group_bytes_uploaded": 4096,
                "staging_object_count": 0,
                "cow_proof_verdict": "PASS",
                "promoted": False,
                "source_unchanged": True
            },
            "probe": {
                "upload_bytes": 8192,
                "upload_window_secs": 60,
                "staging_growth_bytes": 4096,
                "backlog_start": 10000,
                "backlog_end": 5000,
                "degraded": False,
                "window_start": "2026-09-26T11:00:00Z",
                "window_end": "2026-09-26T11:01:00Z"
            },
            "reenable": {
                "situation_slug": "cloud-sync-paused-pending-laststore-redesign-20260719",
                "cleared_by": "Tom",
                "reenable_actor": "Tom",
                "situation_cleared_at": "2026-09-26T10:00:00Z",
                "reenable_at": "2026-09-26T10:30:00Z"
            },
            "catchup": {
                "primary_sync_lag_bytes": 0,
                "staging_depth": 5000,
                "staging_cap": 10000,
                "brain_reads": 5,
                "brain_writes": 3,
                "kanban_reads": 4,
                "kanban_writes": 2,
                "lastgit_reads": 3,
                "lastgit_writes": 1
            },
            "file_blob": {
                "upload_bytes": 2048,
                "fetch_bytes": 2048,
                "upload_route": "upload_file_blob",
                "fetch_route": "download_file_blob",
                "canary_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            }
        }
        json.dump(evidence, f)
        evidence_path = f.name

    # Call without log path
    failures = check_contract.evidence_failures(Path(evidence_path), None)
    assert failures, "Evidence with log hash but no log file should have failures"
    assert any("absent" in f or "log" in f for f in failures), \
        f"Expected log absent error, got: {failures}"

    Path(evidence_path).unlink()
    print("✓ test_evidence_with_log_hash_but_no_log_file_fails")


if __name__ == '__main__':
    try:
        test_evidence_without_provenance_fails()
        test_evidence_with_invalid_log_hash_fails()
        test_evidence_with_matching_log_passes()
        test_evidence_with_log_hash_but_no_log_file_fails()
        print("\nAll tests passed!")
    except AssertionError as e:
        print(f"Test failed: {e}", file=sys.stderr)
        sys.exit(1)
