"""Closed source review for the same-format final-stopped-backup route."""
from native_run_v2_final_changes_a import CHANGES as FIRST
from native_run_v2_final_changes_b import CHANGES as SECOND

REVIEWED_SOURCE = '1d4b205bb84ad3f6dc0a3b4c9d5088e13b499f46'
REVIEWED_TREE = '3cc0d32c3434d044c3f0d436f4026dcd672fa065'
EXACT_CHANGES = {**FIRST, **SECOND}
