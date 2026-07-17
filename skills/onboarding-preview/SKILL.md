---
name: onboarding-preview
description: |
  Spin up the LastDB NEW-USER ONBOARDING wizard locally and drive
  it in a browser — WITHOUT building, signing, or notarizing a desktop app. Runs
  a debug-built node on a throwaway empty DB so the SPA drops into the real
  first-run setup wizard (Key → Identity → AI Setup → Cloud Backup → Apple Data →
  Community → All Set), then opens it and clears the stale localStorage flag that
  otherwise skips it. Use when the user says "try out / preview / test the new
  user onboarding", "run the onboarding flow", "see the first-run experience",
  "show me the setup wizard", "I want to click through onboarding without
  building a node", or "the onboarding wizard isn't showing up". This is the
  fast, no-notarization path — prefer it over `npm run tauri:build` or shipping a
  .dmg whenever the goal is just to see/exercise the onboarding UI.
allowed-tools:
  - Bash
  - Read
  - Edit
triggers:
  - try out the new user onboarding
  - preview onboarding
  - run the onboarding flow
  - first-run experience
  - setup wizard
  - onboarding wizard not showing
---

# Onboarding preview

Goal: let the user see and click through the **real new-user onboarding wizard**
against a local, debug-built node — no build/sign/notarize cycle. Notarization
only matters for distributing a signed `.dmg`; running from source skips all of
it.

## Where the flow lives (for context / edits)

- Wizard UI (React + Vite): `fold/fold_db_node/src/server/static-react/src/components/onboarding/`
  orchestrated by `OnboardingWizard.tsx` (7 steps).
- In production the `dist/` bundle is embedded into the Rust binary via
  rust-embed; in **dev** it's served by a plain Vite dev server with HMR, which
  is what makes this no-build path possible.
- The wizard renders when the backend reports the node is unprovisioned
  (`503 node_not_provisioned`) AND the browser's `folddb_onboarding_complete`
  localStorage flag isn't `"1"`. App entry: `App.tsx`.

## Steps

### 1. Start the node + Vite on an empty DB (background)

From `fold/fold_db_node`, run in the **background** (it's a long-lived dev
server; first boot does a debug compile, ~30–90s):

```bash
cd /Users/tomtang/code/edgevector/fold/fold_db_node
./run.sh --local --local-schema --empty-db
```

- `--local --local-schema` → fully offline (local Sled storage + local schema
  service; no deployed Lambda).
- `--empty-db` → fresh unprovisioned node, so the SPA drops straight into the
  wizard. Uses a throwaway `FOLDDB_HOME=/tmp/folddb-slot-9101`.

Default ports: backend `9101`, Vite `5173` (Vite auto-scans 5173–5299 if busy).

### 2. Wait for it to come up

Poll the run log until Vite reports its URL (do NOT chain `sleep`; use an
until-loop). Capture the log path you redirected to, then:

```bash
until grep -qiE 'Access app at:|localhost:5[12][0-9][0-9]|error\[' "$LOG"; do :; done
grep -iE 'Access app at:|HTTP Port|error\[' "$LOG"
```

Confirm both came up:

```bash
curl -s -o /dev/null -w "vite %{http_code}\n" http://localhost:5173/
```

> Note: probing owner verbs like `/api/auth/login` over bare loopback returns
> `403 transport_not_attested` — that's expected and NOT a failure. Those are
> post-provision owner verbs; the onboarding bootstrap endpoint is allowed
> pre-provision. The wizard works in an unpaired tab.

### 3. Open it in the browser

Open `http://localhost:5173` (the Chrome extension MCP — `navigate` /
`read_page` / `javascript_tool` — is the cleanest way to drive and verify; the
Claude_Preview tools fight over the port since run.sh already owns it).

### 4. ⚠️ Clear the stale localStorage flag (the #1 gotcha)

A browser profile that has completed onboarding before keeps
`folddb_onboarding_complete: "1"`, which **skips the wizard straight into the
main app even on a fresh empty DB**. If you land on the Agent/main view instead
of "KEY SETUP / Choose your root", clear the markers and reload:

```js
['folddb_onboarding_complete','fold_user_id','fold_user_hash']
  .forEach(k => localStorage.removeItem(k));
location.reload();
```

### 5. Verify the wizard renders

Read the page / screenshot. Success looks like the 7-step header
(Key · Identity · AI Setup · Cloud Backup · Apple Data · Community · All Set)
with step 1 **"KEY SETUP — Choose your root"** showing master-password fields and
"Generate new key". Share a screenshot as proof.

### 6. Hand off — things to tell the user

- **Real bootstrap**: "Generate new key" → through the steps calls the actual
  `POST /api/setup/bootstrap` and shows a real 24-word recovery phrase. It's a
  throwaway node, so that phrase isn't precious.
- **Cloud Backup step** hits dev cloud and may fail offline — expected on a local
  node; skip or just observe.
- **After setup**, owner-only features (AI query, etc.) need a *paired* tab — run
  `folddb ui` from `fold/fold_db_node` to open one. The plain `:5173` tab is
  enough for the onboarding itself.
- **Re-trigger onboarding** anytime: clear the localStorage flag (step 4) and
  reload, or re-run with `--empty-db` for a totally clean node, or use Settings →
  "Relaunch onboarding".
- **HMR is live**: edits under `src/components/onboarding/` update the tab
  instantly — good for iterating on copy/layout.

### 7. Cleanup

The dev server stays up until stopped. When the user is done, kill the
background run (the `b...`-style Bash task id, or `pkill -f 'run.sh'` /
`folddb stop` if appropriate — be careful not to kill Tom's primary
LastDB brain; this throwaway node lives under `/tmp/folddb-slot-9101`).

## Lighter fallback: pure UI, no backend

If the goal is only to look at / tweak the screens (no real bootstrap):

```bash
cd /Users/tomtang/code/edgevector/fold/fold_db_node/src/server/static-react
npm install && npm run dev
```

Screens render, but the bootstrap step's `/api/*` calls fail unless mocked (MSW
is already in devDeps). Fine for layout/copy work, not for exercising the real
flow.
