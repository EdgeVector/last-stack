---
name: lastdb_blogpost
description: |
  Author a new blog post on the LastDB marketing site (EdgeVector/fold_db_website,
  thelastdb.com/blog) — a React + Vite + react-router site where each post is its
  own page component with hand-drawn architectural diagrams. Use when the user says
  "write a blog post", "blog post in fold_db_website", "write this up as a LastDB
  blog post", "add a post to the blog", "/lastdb_blogpost", or asks to turn a
  learning / feature / story into a published LastDB blog entry. Handles the whole
  flow: worktree → page component from the template → register in index + router →
  diagrams (the /diagram skill — hand-authored SVG, rendered and eyeballed) →
  build-verify → PR. Does NOT merge — publishing is a human gate.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
triggers:
  - lastdb_blogpost
  - write a blog post
  - blog post in fold_db_website
  - write this up as a blog post
  - add a post to the blog
  - lastdb blog post
---

# /lastdb_blogpost — write a post for the LastDB blog

Codifies how a post gets added to **EdgeVector/fold_db_website** (live at
`https://thelastdb.com/blog`). The site is **React + Vite + react-router**; each
post is a lazy-loaded page component, listed in a blog index and wired into the
router. Diagrams are **hand-authored architectural SVG** — Tom's standing
preference — produced via the **`/diagram` skill** (see §3). **No Mermaid, ever**
(Tom finds it ugly; this is a hard rule, not a default).

Canonical templates to copy structure/voice from (read one before writing):
`src/pages/BlogEvolvingALiveSchema.jsx` (the diagram reference — `ArchFigure`
inline-SVG figures) and `src/pages/BlogDoYouHaveAnApiKey.jsx`.

## 0. Framing & IP gate (decide BEFORE writing) — non-negotiable

The blog's own promise: *"we share how we work, not what's under the hood."* A
LastDB post is **share-the-process / product-positive**, NEVER an IP disclosure.

- ✅ Share: dev process, engineering learnings, product *capabilities* described
  conceptually, the "we build LastDB on LastDB" story, honest debugging tales.
- 🛑 Never include: security/keyring internals, scoped-transform + anything
  patent-adjacent, private-repo source, the moat, internal infra names/ports
  (the brain socket `~/.folddb/data/folddb.sock`, fbrain/fkanban internals), customer/personal data, secrets.
- When a learning touches a real feature (e.g. schema evolution), describe the
  *behavior and the lesson* at a conceptual level — not the implementation.
- If unsure whether something crosses the line, ask the user before writing it.

## 1. Setup — always a worktree

```bash
cd ~/code/edgevector/fold_db_website && git fetch origin -q
WT=~/code/edgevector-worktrees/foldweb-<short-slug>
git worktree add "$WT" -b blog/<slug> origin/main
cd "$WT" && npm install >/dev/null 2>&1
```

Pick a short, URL-safe **slug** (e.g. `evolving-a-live-schema`). It's the route
(`/blog/<slug>`), the canonical URL, and part of the component name.

## 2. Write the page component — `src/pages/Blog<PascalName>.jsx`

Match the template exactly. The structure + the house style classes:

- `import { Link } from 'react-router-dom'`, `Helmet` from `react-helmet-async`,
  and as needed `Section` from `../components/Section`. For diagrams, define a
  small local `ArchFigure({ svg, caption })` helper (copy it from
  `BlogEvolvingALiveSchema.jsx` / `BlogDoYouHaveAnApiKey.jsx`) — no component
  import.
- `<Helmet>` with `<title>… - LastDB</title>`, `meta name="description"`,
  `og:title`, `og:description`, and `<link rel="canonical" href="https://thelastdb.com/blog/<slug>" />`.
- Top + bottom: `<p><Link to="/blog" className="link-btn">[&larr; Blog]</Link></p>`.
- `<h1 className="tagline">Title</h1>` then `<p className="post-meta dim">YYYY-MM-DD</p>`.
- A bold lede: `<p className="bold white">…</p>`.
- Body uses `<h2>`, `<p>`, `<ul>/<ol>`; emphasis via `<span className="bold white">`,
  `<span className="bold">`, `<span className="dim">`, `<em>`.
- Pull-quote / key-lesson callouts: `<Section variant="sage">…</Section>` (calm,
  for definitions/framing) or `<Section variant="rose">…</Section>` (for the
  "here's the catch / the bug" beat). Put an `<h2><span className="bold">…</span></h2>` inside.
- Use HTML entities for punctuation (`&mdash;`, `&rsquo;`, `&ldquo;`/`&rdquo;`,
  `&larr;`/`&rarr;`) — match the existing posts; don't paste raw curly quotes.
- Close with a `<p className="dim">` cross-link (e.g. to `/apps` or the other post).

Voice: concrete, honest, a little playful; lead with the reader's takeaway. Look
at the existing posts and match their register.

## 3. Diagrams — hand-authored architectural SVG (default; use `/diagram`)

**Invoke the `/diagram` skill** and follow it — it carries the full grammar
(thin uniform strokes, poché hatch for "solid/stored", joint marks, dimension
lines, mono caps labels, exactly one accent colour). Don't reinvent the style
here; the `/diagram` skill is the source of truth, and
`src/pages/BlogEvolvingALiveSchema.jsx` is the worked reference. Use the LastDB
gruvbox-dark palette (ink `#928374`, faint `#504945`, text `#ebdbb2`, accent
`#83a598`; transparent bg).

Wiring into the post:

- Define each figure as a backtick **SVG string constant** above the component
  (reuse the `SVG_DEFS` / `SVG_OPEN(viewBox)` helpers from the reference post so
  the `poché` pattern + responsive `<svg>` wrapper are shared).
- Render with the local `ArchFigure` helper:
  `<ArchFigure svg={MY_FIGURE} caption="Fig. N — short caption" />`.
- Keep the SVG as a plain string (it goes through `dangerouslySetInnerHTML`) —
  so use SVG attributes (`stroke-width`, `text-anchor`), not JSX camelCase.

2–3 figures is the sweet spot: one idea per figure. Don't over-diagram prose.

**No Mermaid — ever.** Hand-authored SVG is the *only* diagram style on this
blog. Don't add new `<Mermaid>` charts, and don't offer Mermaid as a fallback —
Tom finds them ugly (standing rule, all repos/docs/chat). The one legacy post
that still uses Mermaid (`BlogBuildingLastdbWithAgents.jsx`) is not a precedent;
convert it to `ArchFigure` SVG if you touch it.

## 4. Register the post (two files)

`src/pages/Blog.jsx` — add to the `POSTS` array, **newest first**:
```js
{ slug: '<slug>', title: '…', date: 'YYYY-MM-DD', blurb: '…' },
```
`src/App.jsx` — add the lazy import next to the other `Blog*` ones, and a route:
```jsx
const Blog<PascalName> = lazy(() => import('./pages/Blog<PascalName>'));
// …inside <Routes>, beside the other /blog/* routes:
<Route path="/blog/<slug>" element={<Blog<PascalName> />} />
```

## 5. Verify (do this — don't hand-wave)

```bash
npm run build           # JSX valid, imports resolve, routes compile
```

**Diagrams — render and LOOK (the `/diagram` skill's non-negotiable step).**
A figure you can't see is one you can't trust. The Claude Preview server is
rooted at the MAIN checkout, not the worktree, so render the figures standalone
and screenshot them:
```bash
# extract the SVG string consts from the page, drop them on the gruvbox bg
node -e 'const fs=require("fs"); const s=fs.readFileSync("src/pages/Blog<PascalName>.jsx","utf8");
  const b=s.slice(s.indexOf("const SVG_DEFS"), s.indexOf("export default")).replace(/export\s+/g,"");
  const o={}; new Function("out", b+"\nout.figs=[/*list your FIG consts*/].join(\"\");")(o);
  fs.writeFileSync("/tmp/figs.html",`<body style="background:#282828;padding:24px;width:720px">${o.figs}</body>`);'
B="$HOME/.claude/skills/gstack/browse/dist/browse"
$B viewport 760x1100; $B goto "file:///tmp/figs.html"; $B screenshot /tmp/figs.png
```
Then **Read `/tmp/figs.png` and actually look** — check for labels colliding
with or overflowing boxes (the #1 mistake), text clipped at the viewBox edge,
connectors not meeting their joints, hatch not rendering. Fix and re-render
until clean. The PR's Vercel preview deploy is the final visual confirmation.

## 6. PR — but DO NOT MERGE (publishing is a human gate)

Commit only the source files (`src/pages/Blog<PascalName>.jsx`, `src/pages/Blog.jsx`,
`src/App.jsx`) — not any worktree-local `.claude/`. Push, open the PR with
`gh pr create -R EdgeVector/fold_db_website --base main`. End the commit/PR body with the standard Co-Authored-By /
Generated-with trailers.

**Stop at the PR.** Merging deploys to the live site (Vercel auto-deploys `main`),
and publishing public/outward content is a human decision (the autonomy
contract's gate #2 — public/outward-facing). Hand the PR + the Vercel **preview
deployment URL** to the user for review; push any requested edits to the branch;
let *them* merge. Pull the preview `*.vercel.app` URL from the PR's commit
statuses:
```bash
gh api repos/EdgeVector/fold_db_website/deployments \
  --jq '.[0].id' | xargs -I{} gh api repos/EdgeVector/fold_db_website/deployments/{}/statuses \
  --jq '.[0].environment_url'
```

## Gotchas
- Worktrees start with **no `node_modules`** — `npm install` first.
- Repo uses a **merge queue** is NOT set here; it's a normal PR + Vercel. Don't
  force-merge; the user merges to publish.
- Keep the post atomic — one post per PR. Don't bundle unrelated site changes.
- After it merges (the user's call), the close-out loop is satisfied by the PR
  itself; no fkanban card needed unless there's follow-up work.
