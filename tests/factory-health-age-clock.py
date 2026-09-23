#!/usr/bin/env python3
"""`age_hours` must age a card on the clock the pipeline cannot reset.

Regression for 2026-09-22: one card fenced 4 ready cards and 6 pickup workers
through the surface-overlap gate, unresolved since 2026-09-17. `age_hours`
read `position`, which fkanban rewrites on every `todo -> doing` move, so the
measured doing-age reset to ~0 on every watch re-dispatch. The `hard_max_age_h
= 5.0` band was crossed and cleared twice on the final day alone and no alert
streak ever formed.

Brain: `papercut-kanban-doing-age-clock-resets-on-re-dispatch`.
"""
import importlib.machinery
import importlib.util
import sys
from datetime import datetime, timezone
from pathlib import Path

command = Path(__file__).resolve().parents[1] / "bin" / "last-stack-factory-health"
spec = importlib.util.spec_from_loader(
    "factory_health", importlib.machinery.SourceFileLoader("factory_health", str(command))
)
module = importlib.util.module_from_spec(spec)
sys.modules["factory_health"] = module
spec.loader.exec_module(module)
age_hours = module.age_hours

HARD_BAND_H = 5.0  # config/factory-health.toml [doing] hard_max_age_h
NOW = datetime(2026, 9, 22, 13, 40, 51, tzinfo=timezone.utc).timestamp()


def iso(dt: datetime) -> str:
    return dt.isoformat().replace("+00:00", "Z")


def epoch_ms(dt: datetime) -> str:
    return str(int(dt.timestamp() * 1000))


failures = []


def check(name, actual, predicate, expectation):
    if predicate(actual):
        return
    failures.append(f"{name}: got {actual!r}, expected {expectation}")


# ── The regression, exactly as measured ────────────────────────────────────
# `position` says the card entered `doing` at 13:39:51Z — 1 minute ago.
# `first_doing_at` says the attempt began on 2026-09-17.
stuck = {
    "slug": "lastdb-streaming-file-blob-put",
    "column": "doing",
    "position": epoch_ms(datetime(2026, 9, 22, 13, 39, 51, tzinfo=timezone.utc)),
    "first_doing_at": iso(datetime(2026, 9, 17, 15, 53, 46, tzinfo=timezone.utc)),
    "updated_at": iso(datetime(2026, 9, 22, 13, 39, 52, tzinfo=timezone.utc)),
}
check(
    "stuck card clears the HARD band",
    age_hours(stuck, NOW),
    lambda v: v > HARD_BAND_H,
    f"> {HARD_BAND_H} (the five-day stall, not the one-minute re-claim)",
)
check(
    "stuck card reports the real stall length",
    round(age_hours(stuck, NOW)),
    lambda v: v == 118,
    "118 hours",
)

# Without the new field this is the number that kept the alarm silent.
legacy_view = {k: v for k, v in stuck.items() if k != "first_doing_at"}
check(
    "position alone still reads under the band (the defect)",
    age_hours(legacy_view, NOW),
    lambda v: v < HARD_BAND_H,
    f"< {HARD_BAND_H}, which is why this needed fixing",
)

# ── Fallbacks: nothing regresses on a board that has no stamp yet ──────────
check(
    "legacy card with no stamp falls back to position",
    age_hours(
        {"position": epoch_ms(datetime(2026, 9, 22, 7, 40, 51, tzinfo=timezone.utc))},
        NOW,
    ),
    lambda v: abs(v - 6.0) < 0.01,
    "6h from position",
)
check(
    "empty stamp falls back to position",
    age_hours(
        {
            "first_doing_at": "",
            "position": epoch_ms(datetime(2026, 9, 22, 7, 40, 51, tzinfo=timezone.utc)),
        },
        NOW,
    ),
    lambda v: abs(v - 6.0) < 0.01,
    "6h from position",
)
check(
    "malformed stamp falls back rather than throwing",
    age_hours(
        {
            "first_doing_at": "not-a-timestamp",
            "position": epoch_ms(datetime(2026, 9, 22, 7, 40, 51, tzinfo=timezone.utc)),
        },
        NOW,
    ),
    lambda v: abs(v - 6.0) < 0.01,
    "6h from position",
)
check(
    "a card with neither clock reports 0, not a crash",
    age_hours({"slug": "bare"}, NOW),
    lambda v: v == 0.0,
    "0.0",
)
check(
    "a stamp in the future clamps to 0",
    age_hours(
        {"first_doing_at": iso(datetime(2026, 9, 23, 0, 0, 0, tzinfo=timezone.utc))},
        NOW,
    ),
    lambda v: v == 0.0,
    "0.0",
)

if failures:
    for line in failures:
        print("FAIL", line)
    raise SystemExit(1)
print("ok factory-health age clock prefers first_doing_at")
