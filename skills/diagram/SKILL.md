---
name: diagram
description: |
  Draw a diagram in Tom's preferred style — technical black-and-white line
  drawings (thin uniform geometric strokes, hatch for solid/stored things,
  dimension lines with ticks, joint marks, plain monospace labels, lots of
  negative space). NO color, NO accent, NO themed palettes, NO gruvbox, NO
  EdgeVector house styling. NOT auto-laid-out Mermaid/Graphviz boxes-and-arrows.
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

# /diagram — technical black-and-white line drawings

Standing owner preference (Tom, **2026-07-31**): diagrams are **black and white,
technical, and unstyled** — like an engineering drawing, not a designed theme.

- **No colour** — black ink only (grays only for hatch/secondary labels).
- **No accent colour**, no gruvbox, no edgevector.org / house CSS tokens.
- **No decorative styling** — no shadows, gradients, rounded marketing boxes,
  coloured fills, or themed fonts (no IBM Plex Mono requirement).

Hand-author **inline SVG**. Prefer this over Mermaid/Graphviz auto-layout unless
Tom asks for something quicker.

Brain: `preference-diagrams-black-and-white-technical`.

## The aesthetic (non-negotiable)

- **Black and white only** — ink `#000000`, paper/transparent bg, optional gray
  `#666666` / `#888888` for hatch and secondary captions. Nothing else.
- **Thin, uniform strokes** — `stroke-width="1"` everywhere. One weight.
- **Sharp geometry** — square corners, right angles, precise polygons. No rounded
  blobs, no drop shadows, no gradients, no solid colour fills (hatch only).
- **Varied shapes, by TYPE** — do NOT make everything a rectangle. Each *kind*
  of thing gets its own shape (see Shape vocabulary), used consistently across
  every figure in the same document.
- **Hatch** for anything "solid" / stored / on-disk (thin diagonal lines — classic
  technical fill). Voids/empties stay outline-only.
- **Dimension lines** (span + short perpendicular end-ticks + label) for quantities.
- **Joint marks** — a tiny 4×4 filled black square where a connector meets a box.
- **Orthogonal connectors** — right-angle elbows (`polyline`), not diagonal
  swooshes. Arrowheads are small precise triangles, used sparingly.
- **Plain monospace labels** — `ui-monospace, SFMono-Regular, Menlo, Consolas, monospace`.
  Primary: `UPPERCASE` title. Secondary: smaller gray caption. No brand fonts.
- **Negative space** — align to an implicit grid; let it breathe.
- **Highlight without colour** — thicker stroke (still black), dashed outline, or
  a simple label — never a second colour.
- Small `figcaption` ("FIG. N — …") under each figure, plain text.

## Shape vocabulary — shape encodes TYPE

Different shapes for different types. Pick one shape per semantic type, keep it
consistent, never collapse into all-rectangles, legend row when 3+ classes:

| shape | means | how to draw |
|---|---|---|
| rectangle | ONLY containers / devices / processes / services — never data | `<rect>` outline |
| cylinder | database / store / persisted bytes | body `<path>` + `<ellipse>` top lid |
| cut-corner document | data record / spec / definition sheet | `<polygon>` clipped corner + fold mark |
| small square | one atomic data unit (atom, log entry) | tiny `<rect>` ~20–34px |
| diamond | decision / check / human consent gate | 4-point `<polygon>` |
| hexagon | sealed / encrypted parcel | 6-point `<polygon>`, flat L/R |
| circle | party / actor / keyholder | `<circle>` |
| person glyph | specifically a human | head `<circle>` + shoulders arc |
| triangle | key / credential | small 3-point `<polygon>` |
| envelope | payload in transit | rect + flap `polyline` |
| star | goal / outcome / north star | 10-point `<polygon>` |

Modifiers: **hatch** = holds real data; **dashed outline** = remote / not yours.
Connectors attach at natural vertices with 4×4 black joint marks.

Snippets (black ink):

```
<!-- cylinder: body + top lid -->
<path d="M 64 106 A 50 9 0 0 1 164 106 L 164 148 A 50 9 0 0 1 64 148 Z"
      fill="url(#hatch)" stroke="#000" stroke-width="1"/>
<ellipse cx="114" cy="106" rx="50" ry="9" fill="#fff" stroke="#000" stroke-width="1"/>
<!-- document: cut top-right corner + fold mark -->
<polygon points="192,98 272,98 286,112 286,156 192,156" fill="none" stroke="#000" stroke-width="1"/>
<polyline points="272,98 272,112 286,112" fill="none" stroke="#000" stroke-width="1"/>
<!-- diamond / hexagon / triangle — all black -->
<polygon points="75,214 175,184 275,214 175,244" fill="none" stroke="#000" stroke-width="1"/>
```

## Palette (only this)

| role | colour | use |
|---|---|---|
| ink | `#000000` | all strokes, joints, primary labels, arrows |
| hatch | `#666666` | hatch pattern lines only |
| dim | `#666666` | captions, secondary labels, dimension text |
| fill void | `#ffffff` or `none` | open interiors; SVG may stay transparent |

**No accent colour. No gruvbox. No blue. No theme tokens.**

If embedding on a dark product UI that already exists, invert only if required for
legibility: white strokes on black — still pure B&W, no accent.

## The SVG toolkit (copy + adapt)

```
<svg viewBox="0 0 660 240" xmlns="http://www.w3.org/2000/svg"
     style="width:100%;height:auto;max-width:660px;display:block;margin:0 auto"
     font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, monospace">
  <defs>
    <pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
      <line x1="0" y1="0" x2="0" y2="6" stroke="#666" stroke-width="1"/>
    </pattern>
  </defs>
  ...
</svg>
```

Building blocks:

- **Labeled box** — outline `stroke="#000"`; title `fill="#000"` UPPERCASE;
  caption `fill="#666"` smaller. Solid/data → `fill="url(#hatch)"`.
- **Joint** — `<rect width="4" height="4" fill="#000"/>`.
- **Connector** — `stroke="#000"`; elbow `polyline`; small triangle arrowhead.
- **Dimension line** — black ticks + span; label `fill="#666"`.
- **Highlight** — same black, e.g. `stroke-width="2"` or `stroke-dasharray="4 3"`,
  never a second colour.

Render:

- **Web / React:** plain SVG string + `figcaption`.
- **Chat:** raw `<svg>` if a visualize/widget tool exists; otherwise save `.svg` / inline.
- **Standalone:** write a `.svg` file.

## Composition checklist

- One idea per figure; 2–3 figures max.
- Shape encodes type; legend if 3+ classes.
- Grid layout; equal margins.
- Solid → hatch. Empty → outline only.
- Quantities → dimension lines.
- Orthogonal connectors + joints; minimise crossings.
- Short labels; no collisions.

## Verify — render it and LOOK

1. Screenshot or open the SVG and actually look.
2. Fix collisions, clipped text, misaligned joints, missing hatch.
3. Confirm **zero non-B&W colours** (no hex blues/greens/oranges).
4. Deliver only when it looks clean and technical.

## Don't

- Don't use colour, accents, gruvbox, house CSS, or brand mono fonts.
- Don't use Mermaid/Graphviz by default when a real technical figure is needed.
- Don't add shadows, gradients, rounded marketing cards, or decorative chrome.
- Don't crowd the figure.
