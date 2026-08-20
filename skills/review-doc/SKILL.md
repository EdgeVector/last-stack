---
name: review-doc
description: |
  Review an HTML or markdown technical document in three sequential passes:
  logic (poke holes), prose (STE / one meaning per word), then diagrams
  (render and look). Use when the user says "review the page 3 times",
  "review this doc", "logic then prose then diagrams", "review-doc",
  or asks to review a LastDB/Last Stack write-up before calling it done.
  This is a review loop. It does not turn the page into the locked design.
---

# review-doc — three passes, then fix

Run the three passes **in order**. Do not skip to polish. After each pass,
**apply** the fixes. A list of issues with no edits is not the skill.

The page under review is a **review** unless the user already named it as
the locked design. Do not retitle it "Architecture note" or "the design."
Locked designs live in brain records. Say so on the page if the page argues.

## Pass 1 — logic (poke holes)

Ask what would make two copies diverge, or a photograph unrestorable.

Check at least:

- **Stamp.** Writer in-memory save, not disk / upload / receive time.
- **Identity.** Same mutation → same atom id and same history key on every
  device. Key includes enough fields to avoid collision (stamp + writer +
  atom id, not apply-time `now()`).
- **Apply.** Idempotent: second apply of the same key is a no-op, no error,
  no extra history row.
- **Visible vs shared.** Overlay (unsent local work) is not the photograph.
  Visible current is last-write-wins of applied cloud list **and** overlay.
  Overlay does not win only because it is local.
- **Photograph.** Built from the shared list at a named frontier, never from
  one local store. After install, put that device's overlay back.
- **Byte identity.** After overlays drain, atoms / current pointers / history
  rows match. Indexes may rebuild. Packed files need not match.
- **Holes.** Clock skew, same-stamp collision, contiguous prefix vs late
  keys from *other* writers, one mutation writing several field history keys.

If a hole is real, patch the page. If it is accepted cost (unfair clock,
lost concurrent edit under last-write-wins), state it as accepted cost.

## Pass 2 — prose

- Apply `instructions/asd-ste100.md` (injected into every harness). One meaning
  per word, active voice, short sentences, no `-ing` as verb or noun, no
  perfect tense, no idiom. Permit one comparison only when Tom asked for ELI5.
- Same word for the same thing for the whole page (stamp, overlay, cloud
  list, photograph, history key).
- Org case: Alice and Bob, one shared head. Personal multi-device is the
  same rules, not a second model.
- Do not call the page a design or a note if it is a review.

## Pass 3 — diagrams

Follow the `diagram` skill (black and white technical drawings).

- Shape encodes type. Legend if 3+ classes.
- Hatch = stored data. Dashed = remote / not yours.
- Orthogonal connectors, joint marks, one stroke weight.
- Figure numbers match document order.
- Render the page (browser screenshot or SVG → PNG) and **look**.
  Fix collisions, hatch-on-text, clipped labels, missing joints.

## After the three passes

- Open the page if the user has been viewing it.
- If the user asked to keep the loop: this skill is the loop. Do not invent
  a fourth pass.
- Do not file the page as a `type: design` brain record unless the user
  locks it.

## Don't

- Don't "review" from memory of an earlier draft. Read the current file.
- Don't skip the render-and-look step for figures.
- Don't promote a working review to locked design in the title block.
