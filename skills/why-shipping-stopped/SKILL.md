---
name: why-shipping-stopped
description: Diagnose why the Last Stack autonomous shipping loop stopped by classifying live evidence into Class A-E and returning the next heal action.
---

# why-shipping-stopped

Use this skill when Tom asks why shipping stopped, why pickup is not draining,
why overnight work stalled, or when factory health shows zero shipped work.

Run the deterministic CLI first:

```bash
last-stack-why-shipping-stopped --json
```

Interpret `class` as:

- `A`: fleet cannot claim work.
- `B`: claim happens but work never lands.
- `C`: merge path is frozen.
- `D`: merged/done signal did not prove the live product.
- `E`: LastDB node/load collapse.
- `none`: no stop condition detected.

Report the `heal` string and the top evidence lines. Do not restart LastDB or
change shared infrastructure based only on this skill; follow the cited heal and
active Situations fences.
