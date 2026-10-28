# Brain CI Workflow Integration for /v2 Publishing

## Current State

Brain (EdgeVector/brain) has:
- Basic CI checks (ci-required.yml, generated-evidence.yml)
- Artifact declaration (.lastgit/artifacts.json)
- App manifest (fbrain.app.json, folddb.toml)
- NO publish workflow yet

## Required Integration

Add to Brain's `.github/workflows/ci-required.yml`:

### Step 1: Add Publish Job (calls host-track-artifact)

```yaml
  publish:
    needs: ci-required
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    permissions:
      contents: read
    uses: EdgeVector/last-stack/.github/workflows/host-track-artifact.yml@main
    with:
      setup-bun: true
      build-command: "bun install --frozen-lockfile && bun run build"
      config: .lastgit/artifacts.json
```

### Step 2: Add /v2 Publish Job (calls publish-app-v2-dev)

```yaml
  publish-v2-dev:
    needs: [ci-required, publish]
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    permissions:
      contents: read
      actions: read
    uses: EdgeVector/last-stack/.github/workflows/publish-app-v2-dev.yml@main
    with:
      app-id: brain
      artifact-name: ht-artifact-${{ github.sha }}
      manifest-path: brain/lastdb-app.json
    secrets:
      LASTDB_API_KEY: ${{ secrets.LASTDB_API_KEY }}
      APP_PUBLISHER_KEY_BASE64: ${{ secrets.BRAIN_PUBLISHER_KEY_BASE64 }}
```

## Prerequisites

Before the workflow can run, Brain repo needs:

### 1. App Manifest

File: `brain/lastdb-app.json`

```json
{
  "app_uuid": "UUID-FROM-REGISTRATION",
  "app_id": "brain",
  "version": "0.1.0",
  "metadata": {
    "display_name": "Brain",
    "description": "Long-term memory over LastDB. Public CLI + MCP — designs, tasks, concepts, preferences, references, agents, projects, spikes, and SOPs with semantic search.",
    "homepage_url": "https://github.com/EdgeVector/brain"
  }
}
```

**Action Required**: Create this file with the correct `app_uuid` for the registered "brain" app.

### 2. GitHub Secrets

Add to EdgeVector/brain repository:

#### LASTDB_API_KEY
- **Type**: Repo secret (or use org-level if available)
- **Value**: Developer API key from Exemem
- **Status**: MISSING - need to check if org secret exists or create new key

#### BRAIN_PUBLISHER_KEY_BASE64
- **Type**: Repo secret
- **Value**: Base64-encoded Ed25519 private key
- **Must derive pubkey**: `EqXMSUwtWnARW+aeOnlAPuu0Dhs3AjFI+WnRpSYnR4w=`
- **Status**: MISSING - need to locate key in LastSecrets or regenerate

### 3. Update .lastgit/artifacts.json

Ensure the manifest is included in the artifact paths:

```json
{
  "artifacts": [
    {
      "app": "brain",
      "paths": [
        "brain/lastdb-app.json",
        "LICENSE",
        "README.md",
        "bin",
        "bun.lock",
        "fbrain.app.json",
        "folddb.toml",
        "package.json",
        "src",
        "tsconfig.json",
        "vendor"
      ],
      "platform": "darwin-arm64"
    }
  ]
}
```

**Action Required**: Add `"brain/lastdb-app.json"` to the paths list.

## Verification Steps

After integration:

1. Push a commit to main in Brain repo
2. Check workflow runs:
   - `publish` job should complete and upload artifact
   - `publish-v2-dev` job should download artifact and publish to /v2
3. Verify release in /v2 DEV:
   ```bash
   curl -sS https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com/v2/apps/brain/releases | jq .
   ```

## Missing Keys Investigation

### Finding the Signing Key

The registered Brain app has `owner_dev_pubkey: EqXMSUwtWnARW+aeOnlAPuu0Dhs3AjFI+WnRpSYnR4w=`

Possible locations:
1. **LastSecrets**: Check for slugs like:
   - `brain-publisher-dev-key`
   - `brain-dev-key`
   - `app-identity-brain-key`
   - `fbrain-publisher-key`

2. **Local dogfood state**: Check `~/.last-stack/dogfood/app-identity/brain/`

3. **Developer machine**: The key used during initial app registration

### If Key is Lost

If the signing key cannot be found:

**Option 1**: Re-register the app with a new key
- Consequence: Breaks existing registry data
- Requires: Admin intervention to revoke old app and register new one

**Option 2**: Recover key from registration process
- Check app-identity-dogfood skill logs
- Check local state on the machine that registered the app

## Next Steps

1. **Locate secrets**: Investigate where LASTDB_API_KEY and signing key exist
2. **Add secrets**: Add them to Brain GitHub repo settings
3. **Create manifest**: Add brain/lastdb-app.json to Brain repo
4. **Update artifacts.json**: Include manifest in artifact paths
5. **Update CI workflow**: Add publish jobs to Brain's ci-required.yml
6. **Test**: Push to main and verify release appears in /v2

## Rollout Plan

### Phase 1: Brain (Current)
- [ ] Locate and configure secrets
- [ ] Create manifest
- [ ] Add workflow integration
- [ ] Test and verify

### Phase 2: LastSecrets
- [ ] Verify app registration
- [ ] Configure secrets
- [ ] Add workflow
- [ ] Test

### Phase 3: lastseek
- [ ] Verify app registration
- [ ] Configure secrets
- [ ] Add workflow
- [ ] Test
