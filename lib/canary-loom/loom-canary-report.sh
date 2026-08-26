#!/usr/bin/env bash
# REPORT node: durable closeout when the heal loop stops without GREEN.
# Effects: idempotent slug upsert. Skips brain when missing or
# CANARY_RED_SKIP_BRAIN=1.
set -euo pipefail

python3 <<'PY'
import datetime, json, os, shutil, subprocess, sys

raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

skip = os.environ.get("CANARY_RED_SKIP_BRAIN") == "1"
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
hour = datetime.datetime.now(datetime.timezone.utc).strftime("%H%M")
exec_id = str(ctx.get("exec_id") or "")
verdict = str(ctx.get("verdict") or "exhausted")
attempt = ctx.get("attempt") or 0
max_attempts = ctx.get("max_attempts") or 3
oid = str(ctx.get("source_git_oid") or "")
diagnosis = str(ctx.get("diagnosis") or ctx.get("retry_reason") or "")
probe = str(ctx.get("probe_tail") or "")[:1500]
retry_id = str(ctx.get("retry_exec_id") or "")

detail = (
    f"exec={exec_id or '-'} verdict={verdict} attempt={attempt}/{max_attempts} "
    f"oid={oid[:12] or '-'} retry={retry_id or '-'}"
)
payload = {
    "outcome": "exhausted" if verdict == "exhausted" else "blocked",
    "detail": detail,
    "reported_at": ts,
}
print("LOOM_CONTEXT_PATCH:" + json.dumps(payload, separators=(",", ":")))

if skip:
    print(f"canary-report skipped-brain {detail}")
    print("PASS")
    raise SystemExit(0)

slug = f"closeout-{stamp}-canary-red-heal-{hour}"
body = f"""---
type: reference
slug: {slug}
title: Closeout — canary RED heal {ts}
status: active
tags: [closeout, lastdb-canary, loom]
---

## What was done

Loom graph `canary-red-heal` stopped without a GREEN canary upgrade.

- failed exec: `{exec_id or "-"}`
- verdict: `{verdict}`
- attempt: {attempt} / {max_attempts}
- oid: `{oid or "-"}`
- retry exec: `{retry_id or "-"}`
- diagnosis: {diagnosis or "(none)"}

## Probe tail

```
{probe or "(none)"}
```

## Why

The loop investigates, lands a fix, and retries the canary upgrade at most
{max_attempts} times. It does not skip the probe bar. It does not file a
kanban card as the only outcome.
"""

if shutil.which("brain"):
    try:
        subprocess.run(
            ["brain", "put"],
            input=body,
            text=True,
            capture_output=True,
            timeout=45,
            check=False,
        )
    except Exception as e:
        print(f"canary-report: brain skipped: {e}", file=sys.stderr)
else:
    print("canary-report: brain not on PATH", file=sys.stderr)

print(f"canary-report {ts} {verdict} {detail}")
print("PASS")
PY
