## Mutation-probe every guard you add — and never read a GREEN probe as a pass

When you add a check, a test, or a lint rule that claims to protect a property,
you must prove it can fail. Introduce the exact defect the guard names, confirm
the guard goes RED, restore the file, and confirm the restore landed.

Use the helper. Do not hand-roll the loop.

```bash
last-stack-mutation-probe --name drop-pin-behind-condition \
  --target bin/last-stack-why-stopped \
  --patch "sed -i '' 's/pin_behind_oid/pin_behind_oid_DISABLED/' bin/last-stack-why-stopped" \
  --test  "bash tests/last-stack-why-stopped-class-h.sh"
```

### Why the helper, and not more care (measured 2026-10-03)

A hand-rolled probe fails in one direction only. When the patch anchor does not
match the file, the patch replaces NOTHING, the guard test then passes, and the
operator reads GREEN as "the guard is fine" or "the property is protected in two
places" — the opposite of the truth, on a verification the rules make mandatory.

Six probes were written for one new guard in EdgeVector/last-stack. Two came back
GREEN on the first attempt and neither guard was weak:

- one patch used 6 spaces of indentation where the file carries 12;
- one wrote the tab escape as `\\\\t` in a Python string literal, which is two
  literal backslashes, where the file holds one.

Both went RED immediately once the probe asserted the file had changed.

`last-stack-mutation-probe` refuses a probe that changed no byte, with its own
exit code, BEFORE it runs the test. A no-op probe therefore cannot produce a
verdict for anyone to misread.

### Exit codes

| code | meaning |
|---|---|
| 0 | the probe behaved as expected (default `--expect red`: the test went RED) |
| 1 | the verdict was not the expected one. With `--expect red`, the guard does NOT catch this defect |
| 2 | usage or environment error |
| 3 | **the patch mutated nothing.** The probe is invalid and there is no verdict. Never read it as a green |
| 4 | the restore did not return every `--target` to its original bytes. The snapshot directory is kept and printed |

### The rules

1. Probe every guard in the same change that adds it. A guard that cannot fail
   reads as coverage and is worse than none.
2. Give `--target` every file the patch touches. A mutation outside the targets
   is invisible to the no-op check and to the restore.
3. A probe that exits 3 is not a result. Fix the patch anchor and run it again.
4. When a probe is unexpectedly GREEN after it mutated the file, find out which
   branch ran. Two causes are both real: the negative fixture is too weak to
   reach the branch (supply a WRONG value, never an absent one), or the property
   is genuinely protected twice. Say which one in the test file.
5. `--expect green` exists for the other direction: proving that a legitimate
   variation is NOT refused. A guard that refuses correct input is its own
   defect.
6. **Put the patch in its own file** and pass `--patch "python3 probes/p3.py"`.
   A patch written inline goes through shell quoting, then the probe's own
   `bash -c`, then whatever language it is in. Measured while shipping this
   helper: five of ten inline probes mutated nothing because an escape level was
   lost in that chain, and one inserted a line whose quotes had become literal,
   so the guard test silently never ran. A patch file has one quoting level.
   Make the patch assert its own anchor count (`assert s.count(old) == 1`) and
   exit non-zero otherwise — then a bad anchor is two independent errors instead
   of one silent one.
