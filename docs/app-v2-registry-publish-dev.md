# App /v2 Registry Publishing (DEV Environment)

## Overview

Apps (Brain, LastSecrets, lastseek) can publish releases to the /v2 DEV app registry
using the `publish-app-v2-dev.yml` reusable workflow. This enables:

- Release tracking in the /v2 registry
- Artifact attestation and signing
- Version compatibility verification
- Integration with the lastdb-verifier

**Environment**: DEV only (`https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com`)

## Workflow Integration

### Example: Brain

Add to `.github/workflows/ci-required.yml` in the Brain repo:

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

## Required Secrets

Each app repo needs these GitHub Actions secrets:

### 1. `LASTDB_API_KEY`

Developer API key for /v2 registry authentication.

**Source**: Exemem developer portal (https://exemem.com) or existing developer enrollment.

**Format**: String API key (e.g. `api_dev_...`)

**Scope**: Can be org-level secret (shared by all apps) or repo-level.

### 2. `{APP}_PUBLISHER_KEY_BASE64`

Ed25519 signing key for release signing. Must match the app's registered
`owner_dev_pubkey` in the /v2 registry.

**App-specific secret names**:
- Brain: `BRAIN_PUBLISHER_KEY_BASE64`
- LastSecrets: `LASTSECRETS_PUBLISHER_KEY_BASE64`
- lastseek: `LASTSEEK_PUBLISHER_KEY_BASE64`

**Source**: The Ed25519 private key used when the app was first registered.

**Format**: Base64-encoded Ed25519 private key (64 bytes raw → ~88 chars base64)

**Storage**: LastSecrets recommended for key generation and backup:
```bash
# Generate new key (only if app is not yet registered)
ssh-keygen -t ed25519 -f brain-publisher-dev.key -N ""

# Extract the raw private key bytes (32 bytes seed)
# or use the full private key file
cat brain-publisher-dev.key | base64 | tr -d '\n'

# Store in LastSecrets for backup
lastsecrets set brain-publisher-dev-key < brain-publisher-dev.key
```

## Registered Apps and Keys

### Brain

- **App ID**: `brain`
- **Registered**: 2026-08-06
- **Owner Dev Pubkey**: `EqXMSUwtWnARW+aeOnlAPuu0Dhs3AjFI+WnRpSYnR4w=`
- **Source**: https://github.com/EdgeVector/brain

**Key location**: The Ed25519 private key that derives this pubkey must be:
1. Stored in GitHub as `BRAIN_PUBLISHER_KEY_BASE64` (base64-encoded)
2. Backed up in LastSecrets (recommended slug: `brain-publisher-dev-key`)

### LastSecrets

- **App ID**: TBD (needs verification - may be `lastsecrets`)
- **Registered**: TBD
- **Owner Dev Pubkey**: TBD

### lastseek

- **App ID**: `lastseek`
- **Registered**: TBD
- **Owner Dev Pubkey**: TBD

## Setup Checklist

For each app (Brain, LastSecrets, lastseek):

- [ ] Verify app is registered in /v2 DEV:
  ```bash
  curl -sS https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com/v2/apps/{app_id} | jq .
  ```

- [ ] Verify `owner_dev_pubkey` matches available signing key:
  ```bash
  # If the key is in LastSecrets:
  lastsecrets get {app}-publisher-dev-key | {derive-pubkey-command}
  
  # Compare to registered pubkey
  ```

- [ ] Add GitHub secrets to app repo:
  - `LASTDB_API_KEY` (org-level or repo-level)
  - `{APP}_PUBLISHER_KEY_BASE64` (repo-level)

- [ ] Add workflow call to app's CI (see example above)

- [ ] Verify manifest exists in artifact:
  - Brain: `brain/lastdb-app.json`
  - LastSecrets: `lastsecrets.app.json` or similar
  - lastseek: `lastseek.app.json` or similar

- [ ] Test workflow on a push to main

- [ ] Verify release appears in /v2:
  ```bash
  curl -sS https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com/v2/apps/{app_id}/releases | jq .
  ```

## Missing Prerequisites Report

If any required secret is missing, the workflow will fail with a clear error.
Document missing items here:

### Brain

**Status**: BLOCKED - missing secrets

1. **LASTDB_API_KEY**: 
   - **Where**: GitHub org secret or Brain repo secret
   - **What**: Developer API key from Exemem
   - **How to obtain**: TBD - check existing developer enrollment or request new key

2. **BRAIN_PUBLISHER_KEY_BASE64**:
   - **Where**: Brain repo secret
   - **What**: Ed25519 private key that derives pubkey `EqXMSUwtWnARW+aeOnlAPuu0Dhs3AjFI+WnRpSYnR4w=`
   - **Backup location**: LastSecrets at `brain-publisher-dev-key` (verify if exists)
   - **How to obtain**: 
     1. Check if key exists in LastSecrets: `lastsecrets list | grep brain`
     2. If exists: `lastsecrets get brain-publisher-dev-key | base64 | tr -d '\n'`
     3. If not exists: Key may be lost; app re-registration may be required

### LastSecrets

**Status**: Not started

### lastseek

**Status**: Not started

## Troubleshooting

### Key Mismatch Error

If `lastdb app release-publish` fails with a key mismatch error:

1. Verify the base64-decoded key matches the registered pubkey
2. Check if the app was registered with a different key
3. If key is lost, app may need re-registration (breaking change)

### Manifest Not Found

If manifest is missing from the artifact:

1. Ensure `{app}/lastdb-app.json` exists in the repo
2. Verify `.lastgit/artifacts.json` includes the manifest in the `paths` list
3. Check the artifact upload in the host-track-artifact job

### API Key Invalid

If LASTDB_API_KEY is rejected:

1. Verify key is for DEV environment (not prod)
2. Check if developer account is active
3. Verify API key has not expired

## References

- Design: docs/designs/exemem-app-registry-simple.md
- lastdb PR #641: /v2 publishing integration guide
- Workflow: .github/workflows/publish-app-v2-dev.yml
- DEV Registry: https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com/v2/apps
