# LastDB refcount reachability audit

This directory contains the former schema-root copy-only proof harness. It is
now a periodic audit. It is not registered with `last-stack-north-star-proof`.

`produce.py` writes both documents from a running `lastdb-dev` CoW copy. It
uses the refcount grace-window candidate list and the daemon liveness walker.
It refuses a primary home, a home without a CoW owner stamp, and a stopped copy.

The candidate document has this form:

```json
{
  "schema": "lastdb-atom-refcount-grace-window-delete.v1",
  "surface": {"kind": "isolated-copy", "copy_id": "cow-20260928"},
  "candidates": [{"atom_id": "atom-1", "refcount": 0, "grace_elapsed": true}]
}
```

The liveness walker writes a reachability document. It preserves schema catalog,
retention, and system root groups for each live candidate.

```json
{
  "schema": "lastdb-schema-root-reachability.v1",
  "surface": {"kind": "isolated-copy", "copy_id": "cow-20260928"},
  "roots": {"schema_catalogs": ["schema-a"], "retention": [], "system": []},
  "objects": [{"id": "schema-a", "references": ["protein-a"]}, {"id": "protein-a", "references": ["atom-1"]}]
}
```

Produce and run the audit from the same isolated copy:

```bash
python3 produce.py --copy-home /path/to/cow --out-dir /tmp/refcount-input
python3 audit.py \
  --candidates /tmp/refcount-input/candidates.json \
  --reachability /tmp/refcount-input/reachability.json --out audit.json
```

`result: agreement` means no candidate is reachable. `result: disagreement`
means at least one zero-count candidate is live. The program returns zero for
either result. A disagreement requires a refcount bookkeeping bug card. It
does not block a North Star or close a card.
