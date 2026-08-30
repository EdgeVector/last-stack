# north-star-exemem-cloud-account proof

`run.sh` proves the North Star two ways. Both report `PASS` in live mode.

| Path | Input | Use it when |
|---|---|---|
| CLI drive | `EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME` | you hold a throwaway copy of a connected identity |
| Evidence file | `EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE` | any machine, including CI |

`evidence/live-evidence.json` is the committed artifact for the second path. It
came from the real paid account on 2026-08-30.

## Regenerate the evidence file

```bash
throwaway="$(mktemp -d)"
cp ~/.lastdb/cloud_sync.json "$throwaway/cloud_sync.json"   # read-only copy
EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME="$throwaway" \
  harness/north-star/exemem-cloud-account/collect-live-evidence.sh \
  --out harness/north-star/exemem-cloud-account/evidence/live-evidence.json
rm -rf "$throwaway"
```

The collector reads only. It never runs `lastdb cloud setup-paid`, never runs
`lastdb cloud upgrade` (only `--help`), and refuses `~/.lastdb`. Per brain
`decision-2026-08-17-exemem-proof-use-existing-paid-account`, the account that
is already paid is the evidence; an agent never completes a checkout.

## What must never reach a file

The account endpoint hands the calling device a short-lived bearer token, and
the account URL carries a query secret. Neither belongs in the committed
evidence file or in the durable report under `~/.last-stack/north-star-proofs/`.
`run.sh` redacts credential-named keys at any depth, scrubs those values out of
the captured status text, and prints the report only after proving that no
collected secret survives in it. The test file holds a stubbed drive that fails
if a nested token ever reaches the report again.
