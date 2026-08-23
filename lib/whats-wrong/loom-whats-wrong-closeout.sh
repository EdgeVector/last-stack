#!/usr/bin/env bash
# CLOSEOUT node: brain report + papercuts for remaining exceptions, heartbeat.
# Effects: idempotent (slug upserts). Skips LastDB writes when brain is missing
# or WHATS_WRONG_SKIP_BRAIN=1 (tests).
set -euo pipefail

python3 <<'PY'
import datetime, json, os, subprocess, sys, tempfile

raw = os.environ.get("LOOM_INPUT") or "{}"
try:
    ctx = json.loads(raw)
except json.JSONDecodeError:
    ctx = {}

items = ctx.get("items") or []
results = ctx.get("heal_results") or []
dashboard = str(ctx.get("dashboard") or "http://127.0.0.1:7733")
count = ctx.get("count")
if count is None:
    count = len(items) if isinstance(items, list) else 0
try:
    count = int(count)
except (TypeError, ValueError):
    count = 0

def as_dict(v):
    if isinstance(v, dict):
        return v
    if isinstance(v, str):
        try:
            parsed = json.loads(v)
            return parsed if isinstance(parsed, dict) else {}
        except json.JSONDecodeError:
            return {}
    return {}

healed, remaining, filed = [], [], []
item_ids = []
for it in items if isinstance(items, list) else []:
    if isinstance(it, dict) and it.get("id"):
        item_ids.append(str(it.get("id")))

for i, r in enumerate(results if isinstance(results, list) else []):
    row = as_dict(r)
    if "heal_status" not in row:
        for key in ("result", "output", "context", "stdout"):
            inner = row.get(key) if isinstance(row, dict) else None
            parsed = as_dict(inner) if not isinstance(inner, dict) else inner
            if parsed.get("heal_status") or parsed.get("id"):
                row = parsed
                break
    hid = str(row.get("id") or (item_ids[i] if i < len(item_ids) else ""))
    st = str(row.get("heal_status") or "")
    pc = str(row.get("papercut") or "")
    if st == "healed":
        healed.append(hid or "?")
    else:
        remaining.append(hid or (item_ids[i] if i < len(item_ids) else "?"))
        if pc:
            filed.append(pc)

if not results and item_ids:
    remaining = list(item_ids)

skip_brain = os.environ.get("WHATS_WRONG_SKIP_BRAIN") == "1" or os.environ.get("WHATS_WRONG_DRY") == "1"
now = datetime.datetime.now(datetime.timezone.utc)
stamp = now.strftime("%Y%m%d")
hour = now.strftime("%H%M%S")
slug = f"closeout-{stamp}-whats-wrong-{hour}"
ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")

if count == 0 and not remaining:
    outcome = "noop"
    detail = "exceptions=0"
else:
    outcome = "ok"
    detail = f"exceptions={count} healed={len(healed)} remaining={len(remaining)}"

title = f"Closeout — what's-wrong {ts}"
body = f"""---
type: reference
slug: {slug}
title: {title}
tags: [closeout, whats-wrong, ops-terminal]
---

## What was done
Hourly EV OPS What's wrong pass against {dashboard}. Listed coverage.exceptions
and fanned one loom heal agent per row (cap {count}).

## Why
Dashboard exceptions are the live "something is wrong" list. Each row gets its
own agent so disk, loom, doctor, and ship stalls do not serialize behind one
budget.

## Proof
- Claim: one heal agent per What's wrong row, then a closeout record.
- How: loom graph whats-wrong; snapshot coverage.exceptions.
- Verified: exceptions={count} healed={len(healed)} remaining={len(remaining)}

## Artifacts
- Dashboard: {dashboard}
- Healed: {', '.join(healed) or 'none'}
- Remaining: {', '.join(remaining) or 'none'}

## Papercuts filed
{chr(10).join('- ' + p for p in filed) if filed else '- none — remaining rows should already have been filed by the heal agent, or the list was empty'}

## Follow-ups
none from the parent graph (heal agents file papercuts; papercut-reconciler cards)

## Leftovers
{', '.join(remaining) or 'none'}
"""

if not skip_brain:
    try:
        subprocess.run(["bash", "-lc", "command -v brain >/dev/null"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with tempfile.NamedTemporaryFile("w", prefix="whats-wrong-closeout-", suffix=".md", delete=False) as fh:
            fh.write(body)
            path = fh.name
        try:
            subprocess.run(["brain", "put", slug, "--type", "reference"], stdin=open(path, encoding="utf-8"), check=False, timeout=30)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
    except Exception as e:
        print(f"whats-wrong-closeout: brain skipped: {e}", file=sys.stderr)

line = f"whats-wrong {ts} {outcome} {detail}"
if not skip_brain:
    hb = os.environ.get("LAST_STACK_ROOT") or os.path.expanduser("~/.last-stack")
    helper = os.path.join(hb, "bin", "last-stack-brain-append-heartbeat")
    if os.path.isfile(helper) and os.access(helper, os.X_OK):
        subprocess.run([helper, "--line", line], check=False, timeout=10)

patch = {
    "outcome": outcome,
    "detail": detail,
    "healed": healed,
    "remaining": remaining,
    "closeout_slug": slug,
}
print("LOOM_CONTEXT_PATCH:" + json.dumps(patch, separators=(",", ":")))
print(line)
print("PASS")
PY
