---
name: diagram
description: |
  Draw a diagram in Tom's preferred style — a hand-drawn ARCHITECTURAL / draftsman
  line drawing (thin uniform geometric strokes, poché hatch for "solid"/stored
  things, dimension lines with ticks, joint marks, monospace small-caps labels,
  lots of negative space, exactly one accent colour). NOT auto-laid-out
  Mermaid/Graphviz boxes-and-arrows — those look generic and Tom dislikes them.
  Use whenever Tom asks to "draw a diagram", "make/render/sketch a diagram",
  "diagram this", "show me a diagram", "add a figure", or wants a visual of an
  architecture / flow / data model / system. This is the DEFAULT diagram style;
  hand-author inline SVG, then render it and look at it before delivering.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
triggers:
  - draw a diagram
  - draw the diagram
  - make a diagram
  - diagram this
  - render a diagram
  - sketch a diagram
  - show me a diagram
  - add a figure
---

# /diagram — architectural line drawings, hand-authored

Tom's standing preference: diagrams should look like **a drawing a building
architect would make** — minimal, very geometric, precise, designed. Reach for
**hand-authored inline SVG**, never Mermaid/Graphviz auto-layout (he called those
"kind of ugly"). The reference that set this preference is the LastDB blog post
`fold_db_website/src/pages/BlogEvolvingALiveSchema.jsx` — open it for a worked
example of all the pieces below.

## The aesthetic (non-negotiable)

- **Thin, uniform strokes** — `stroke-width="1"` everywhere. One weight.
- **Sharp geometry** — square corners, right angles, precise polygons. No rounded
  blobs, no drop shadows, no gradients, no fills except hatch.
- **Varied shapes, by TYPE** — do NOT make everything a rectangle. Each *kind*
  of thing gets its own shape (see Shape vocabulary below), used consistently
  across every figure in the same document. Tom explicitly asked for this
  (2026-07-16): "I don't want everything to be rectangles."
- **Poché hatch** for anything "solid" / stored / on-disk (a thin diagonal line
  pattern — the classic architectural fill). Voids/empties stay outline-only.
- **Dimension lines** (a span line with short perpendicular end-ticks + a label
  underneath) to measure/label quantities — like a real drawing.
- **Joint marks** — a tiny 4×4 filled square where a connector meets a box.
- **Orthogonal connectors** — right-angle elbows (`polyline`), not diagonal
  swooshes. Arrowheads are small precise triangles, used sparingly.
- **Monospace labels** in two registers: a primary `UPPERCASE` title
  (letter-spacing ~1.5) + a lowercase dim caption. Mono font throughout.
- **Negative space** — align everything to an implicit grid; let it breathe.
- **One accent colour only**, reserved for the "new"/highlighted element. Every
  other line is the muted structural colour.
- A small `figcaption` ("FIG. N — …", uppercase, dim) under each figure.

## Shape vocabulary — shape encodes TYPE

Different shapes for different types of things. Pick one shape per semantic
type, keep it consistent across all figures in a document, and never let a
diagram collapse into all-rectangles. The working set (extend it in the same
spirit when a new type appears):

| shape | SVG | means |
|---|---|---|
| plain rectangle | `<rect>` outline | container / machine / surface (a laptop, a device, a board) |
| rectangle + poché | `<rect fill=hatch>` | data at rest — a store, a database, persisted bytes |
| small square | tiny `<rect>` (~20–34px) | one atomic data unit (an atom, a log entry); hatch if persisted, accent outline if in flight |
| circle | `<circle>` | a record/object/pointer (a molecule, a knowledge graph — add 2px dots + hairline links inside for "graph") |
| hexagon | `<polygon>` 6-pt, flat left/right vertices | a process/service that computes (a resolver, a daemon); **dashed** outline when remote / not yours |
| clipped-corner card | `<path>` rect with one corner cut ~16px | a definition/spec sheet — schema, contract, config; field rows as underlined lines inside |
| diamond | `<polygon>` 4-pt | a decision / check / validation gate |
| person glyph | head `<circle>` + shoulders arc (`M x y Q …`) | a human actor (Alice, a recipient) |
| envelope | rect + `polyline` flap | a payload in transit |
| star | 10-pt `<polygon>` | a goal / outcome / north star |

Connectors attach to a shape's natural vertex (hexagon side points, diamond
tips, a card's straight edge) with the usual 4×4 joint marks. Poché and dashed
outlines compose with any shape — hatch = "holds data", dashed = "remote or
out of your control" — so e.g. a dashed hexagon with a hatched rect inside
reads "remote service storing ciphertext".

## Palette

Match the surface you're drawing onto. Pull its CSS variables when embedding in
a themed app. Absent a given palette, use this draftsman default (gruvbox-dark,
what LastDB uses):

| role | colour | use |
|---|---|---|
| ink | `#928374` | structural strokes, dimension lines, joints |
| faint | `#504945` | hatch lines, cell dividers, dashed guides |
| text | `#ebdbb2` | primary labels |
| dim | `#928374` | captions, secondary labels |
| accent | `#83a598` | the ONE highlighted element ("new", "v2", …) |
| bg | `#282828` | (transparent SVG; the surface provides it) |

Light/blueprint surface? Invert: ink `#3b4a5a`, faint `#c3cdd6`, text `#1c2733`,
accent `#2f6f8f`, on a near-white bg. Keep the same grammar.

## The SVG toolkit (copy + adapt)

Open the SVG with a responsive wrapper and shared `<defs>`:

```
<svg viewBox="0 0 660 240" xmlns="http://www.w3.org/2000/svg"
     style="width:100%;height:auto;max-width:660px;display:block;margin:0 auto"
     font-family="'IBM Plex Mono', monospace">
  <defs>
    <pattern id="poche" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
      <line x1="0" y1="0" x2="0" y2="6" stroke="#504945" stroke-width="1"/>
    </pattern>
    <pattern id="cells" width="24" height="40" patternUnits="userSpaceOnUse">
      <line x1="0" y1="0" x2="0" y2="40" stroke="#504945" stroke-width="1"/>
    </pattern>
  </defs>
  ...
</svg>
```

Building blocks:

- **Labeled box** — `<rect x y width height fill="none" stroke="#928374" stroke-width="1"/>`
  with a centred `UPPERCASE` title (`#ebdbb2`, `font-size="13"`, `letter-spacing="1.5"`,
  `text-anchor="middle"`) and a dim caption below it (`#928374`, `font-size="11"`).
  For a "solid/data" box, add a second rect with `fill="url(#poche)"`. For a
  "cells/fields strip", overlay `fill="url(#cells)"`.
- **Joint** — `<rect x y width="4" height="4" fill="#928374"/>` at each connection point.
- **Spine / connector** — straight: `<line .../>`; elbowed: `<polyline points="x1,y1 x1,y2 x2,y2" fill="none" stroke=.../>`.
  Arrowhead: `<polygon points="tipx,tipy bx,by bx,by2" fill=.../>` (a small triangle).
- **Dimension line** — span + end-ticks + label:
  ```
  <line x1="A" y1="Y" x2="A" y2="Y+14" stroke="#928374"/>   <!-- left tick -->
  <line x1="B" y1="Y" x2="B" y2="Y+14" stroke="#928374"/>   <!-- right tick -->
  <line x1="A" y1="Y+7" x2="B" y2="Y+7" stroke="#928374"/>  <!-- span -->
  <text x="(A+B)/2" y="Y+30" text-anchor="middle" fill="#928374" font-size="10">10 FIELDS — LABEL</text>
  ```
  Use the accent colour for the dimension of the highlighted span.
- **Alignment guide** — faint dashed vertical/horizontal line tying two rows
  together: `stroke="#504945" stroke-dasharray="2 3"`.

Render in a host:
- **Web / React (JSX):** wrap in a tiny `ArchFigure({svg, caption})` that does
  `<div dangerouslySetInnerHTML={{__html: svg}} />` + a `<figcaption>` (see the
  reference post). Keeps the SVG as a plain string — no JSX attribute conversion.
- **A reply in chat:** deliver it through the `visualize` MCP tool
  (`mcp__visualize__show_widget`) — pass the raw `<svg …>` as `widget_code` (it
  auto-detects SVG). Use CSS variables for colours so it themes.
- **Standalone:** write a `.svg` file.

## Composition checklist
- Decide the ONE idea each figure carries; one figure per idea, 2–3 max.
- Lay out on a grid; equal margins; consistent box sizes.
- "Solid/has data" → poché. "Empty/void/new" → outline only (often the accent).
- Quantities → dimension lines, not prose inside the box.
- Connectors → orthogonal elbows with joints. Minimise crossings.
- Labels: UPPERCASE title + dim caption. Keep captions SHORT so they don't
  collide with a neighbouring box (the #1 mistake — see Verify).

## Verify — render it and LOOK (do not skip)

A diagram you can't see is a diagram you can't trust. After authoring:

1. Get it on screen. Web post: dev server (`npm run dev`) + headless browser:
   ```bash
   B="$HOME/.claude/skills/gstack/browse/dist/browse"
   $B viewport 1100x900; $B goto "http://localhost:<port>/<route>"
   $B screenshot /tmp/fig.png --selector "article figure:nth-of-type(N)"
   ```
   Then **Read /tmp/fig.png** and actually look. Standalone SVG: `$B goto file://<abs>.svg` + screenshot. Chat widget: the `visualize` tool renders it for the user directly.
2. Check for: labels overflowing or colliding with boxes (shorten the caption or
   move it), text clipped at the viewBox edge, misalignment, the hatch/cells not
   rendering, an arrow not meeting its box. Fix and re-render until clean.
3. Only deliver once you've seen it look right.

(On the reference post, the first pass had a caption running into a box; a
re-screenshot caught it. Always do the second look.)

## Don't
- Don't fall back to Mermaid/Graphviz/ASCII because it's faster — the whole point
  is the hand-drawn architectural look.
- Don't add colour beyond the one accent. Don't add shadows/gradients/rounded
  corners. Don't crowd it.
