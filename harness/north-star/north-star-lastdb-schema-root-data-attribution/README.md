# LastDB refcount reachability audit

This directory contains the former schema-root copy-only proof harness. It is
now a periodic audit. It is not registered with `last-stack-north-star-proof`.

The atom-refcount grace-window delete job writes a candidate document:

```json
{
  "schema": "lastdb-atom-refcount-grace-window-delete.v1",
  "surface": {"kind": "isolated-copy", "copy_id": "cow-20260928"},
  "candidates": [{"atom_id": "atom-1", "refcount": 0, "grace_elapsed": true}]
}
```

The isolated-copy walker writes a reachability document. It starts at schema
catalog, retention, and system roots. Each object names every direct reference.

```json
{
  "schema": "lastdb-schema-root-reachability.v1",
  "surface": {"kind": "isolated-copy", "copy_id": "cow-20260928"},
  "roots": {"schema_catalogs": ["schema-a"], "retention": [], "system": []},
  "objects": [{"id": "schema-a", "references": ["protein-a"]}, {"id": "protein-a", "references": ["atom-1"]}]
}
```

Run the audit with one candidate document and one reachability document from
the same isolated copy:

```bash
python3 harness/north-star/north-star-lastdb-schema-root-data-attribution/audit.py \
  --candidates candidates.json --reachability reachability.json --out audit.json
```

`result: agreement` means no candidate is reachable. `result: disagreement`
means at least one zero-count candidate is live. The program returns zero for
either result. A disagreement requires a refcount bookkeeping bug card. It
does not block a North Star or close a card.
