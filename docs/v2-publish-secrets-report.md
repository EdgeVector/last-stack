# /v2 App Registry Publishing - Secrets Report

## Summary

This report details the required secrets for publishing Brain, LastSecrets, and lastseek
releases to the /v2 DEV app registry (`https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com`).

**Status**: Implementation ready, pending secret configuration.

## Implementation

### Created Files

1. **`.github/workflows/publish-app-v2-dev.yml`**
   - Reusable workflow for publishing app releases to /v2 DEV
   - Downloads artifact from host-track-artifact
   - Calls `lastdb app release-publish` CLI
   - DEV environment only (hardcoded URL)

2. **`docs/app-v2-registry-publish-dev.md`**
   - Integration guide for app repositories
   - Secret requirements and formats
   - Troubleshooting steps

3. **`docs/brain-ci-workflow-integration.md`**
   - Brain-specific integration instructions
   - Prerequisite checklist
   - Missing keys investigation guide

4. **`examples/brain-ci-required-with-v2-publish.yml`**
   - Reference implementation showing Brain workflow with /v2 publishing
   - Copy-paste ready job definition

## Required Secrets

### 1. LASTDB_API_KEY

**Purpose**: Developer API key for /v2 registry authentication

**Scope**: Organization-wide (can be shared by all apps) or per-repo

**Format**: String API key (e.g., `api_dev_...`)

**Where to add**:
- **Option A (Recommended)**: EdgeVector organization secret
  - Accessible to all repos
  - Single point of management
- **Option B**: Individual repo secrets
  - EdgeVector/brain: `LASTDB_API_KEY`
  - EdgeVector/lastsecrets: `LASTDB_API_KEY`
  - EdgeVector/lastseek: `LASTDB_API_KEY`

**Source**: Exemem developer portal or existing developer enrollment

**Current Status**: ❌ MISSING
- Cannot list org/repo secrets via gh API (403 permissions)
- Need to check GitHub org settings manually or via admin access
- May already exist from previous app-identity-dogfood work

**How to check**:
```bash
# As org admin, check in GitHub UI:
# https://github.com/organizations/EdgeVector/settings/secrets/actions

# Or via API with admin token:
gh api /orgs/EdgeVector/actions/secrets --jq '.secrets[].name' | grep -i lastdb
```

**If missing, how to obtain**:
1. Check existing developer enrollment in Exemem DEV
2. Check LastSecrets for `lastdb-api-key-dev` or similar slug
3. Check app-identity-dogfood state: `~/.last-stack/dogfood/app-identity/brain/`
4. If not found, generate new key via Exemem developer portal

### 2. BRAIN_PUBLISHER_KEY_BASE64

**Purpose**: Ed25519 private key for signing Brain releases

**Scope**: Brain repo only

**Format**: Base64-encoded Ed25519 private key
- Raw key: 32-64 bytes
- Base64: ~88 characters
- Example: `LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS...==`

**Where to add**: EdgeVector/brain repository secret
- Name: `BRAIN_PUBLISHER_KEY_BASE64`
- Visibility: Private (not accessible to PRs from forks)

**Must derive pubkey**: `EqXMSUwtWnARW+aeOnlAPuu0Dhs3AjFI+WnRpSYnR4w=`
- This is the registered `owner_dev_pubkey` for app "brain" in /v2 DEV
- The signing key MUST produce this exact pubkey or releases will be rejected

**Current Status**: ❌ MISSING - REQUIRES INVESTIGATION

**Possible locations**:
1. **LastSecrets**: Check for these slug patterns:
   ```bash
   lastsecrets list | grep -iE 'brain|publisher|dev.*key'
   ```
   Likely slugs:
   - `brain-publisher-dev-key`
   - `brain-dev-key`
   - `app-identity-brain-key`
   - `fbrain-publisher-key`

2. **Local dogfood state**: Machine that ran app-identity-dogfood
   ```bash
   ls -la ~/.last-stack/dogfood/app-identity/brain/
   # Look for .key, .pem, or key files
   ```

3. **Developer machine**: Original machine used to register "brain" app on 2026-08-06

**If found in LastSecrets**:
```bash
# Extract and base64-encode the key
lastsecrets get brain-publisher-dev-key | base64 | tr -d '\n'

# Add to Brain repo as BRAIN_PUBLISHER_KEY_BASE64
```

**If key is lost**: ⚠️ CRITICAL ISSUE
- Cannot publish releases for existing "brain" app
- Would require app re-registration with new key
- Breaks continuity with existing registry data
- Requires coordination with registry admin

### 3. LASTSECRETS_PUBLISHER_KEY_BASE64

**Purpose**: Ed25519 private key for signing LastSecrets releases

**Scope**: lastsecrets repo only

**Where to add**: EdgeVector/lastsecrets repository secret

**Current Status**: ❌ NOT INVESTIGATED YET

**Action Required**:
1. Verify LastSecrets is registered in /v2 DEV:
   ```bash
   curl -sS https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com/v2/apps/lastsecrets | jq .
   ```
2. Note the `owner_dev_pubkey`
3. Locate the corresponding private key (same process as Brain)

### 4. LASTSEEK_PUBLISHER_KEY_BASE64

**Purpose**: Ed25519 private key for signing lastseek releases

**Scope**: lastseek repo only

**Where to add**: EdgeVector/lastseek repository secret

**Current Status**: ❌ NOT INVESTIGATED YET

**Action Required**:
1. Verify lastseek is registered in /v2 DEV:
   ```bash
   curl -sS https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com/v2/apps/lastseek | jq .
   ```
2. Note the `owner_dev_pubkey`
3. Locate the corresponding private key (same process as Brain)

## Registered Apps in /v2 DEV

### brain

```json
{
  "app_id": "brain",
  "owner_dev_pubkey": "EqXMSUwtWnARW+aeOnlAPuu0Dhs3AjFI+WnRpSYnR4w=",
  "registered_at": "2026-08-06T00:09:24Z",
  "source": "https://github.com/EdgeVector/brain",
  "tier": "live",
  "metadata": {
    "display_name": "Brain",
    "description": "Long-term memory over LastDB. Public CLI + MCP — designs, tasks, concepts, preferences, references, agents, projects, spikes, and SOPs with semantic search.",
    "homepage_url": "https://github.com/EdgeVector/brain"
  }
}
```

**Releases**: 0 (confirmed empty on 2026-10-28)

### lastsecrets

**Status**: Need to verify registration and pubkey

### lastseek

**Status**: Need to verify registration and pubkey

## Action Items

### Immediate (Brain DEV Publishing)

- [ ] **Locate LASTDB_API_KEY**
  - Check GitHub org secrets
  - Check LastSecrets: `lastsecrets list | grep api`
  - Check dogfood state
  - If missing, generate new key

- [ ] **Locate BRAIN_PUBLISHER_KEY_BASE64**
  - Check LastSecrets: `lastsecrets list | grep -i brain`
  - Check dogfood state: `~/.last-stack/dogfood/app-identity/brain/`
  - Check original registration machine
  - **CRITICAL**: If lost, escalate immediately

- [ ] **Add secrets to GitHub**
  - Add `LASTDB_API_KEY` to EdgeVector org secrets
  - Add `BRAIN_PUBLISHER_KEY_BASE64` to EdgeVector/brain repo secrets

- [ ] **Create Brain manifest**
  - File: `brain/lastdb-app.json` in Brain repo
  - Must include `app_uuid` field
  - Add to `.lastgit/artifacts.json` paths

- [ ] **Update Brain CI workflow**
  - Add `publish-v2-dev` job (see `examples/brain-ci-required-with-v2-publish.yml`)
  - Test on main branch push

- [ ] **Verify first release**
  ```bash
  curl -sS https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com/v2/apps/brain/releases | jq .
  ```

### Next Steps (LastSecrets and lastseek)

- [ ] Verify lastsecrets and lastseek registration details
- [ ] Locate their publisher keys
- [ ] Add their secrets
- [ ] Update their CI workflows
- [ ] Test publishing

## Risk Assessment

### High Risk: Lost Publisher Keys

If any app's publisher key is lost:
- **Impact**: Cannot publish releases for that app
- **Mitigation**: App re-registration required (breaks continuity)
- **Probability**: Medium (key may exist in LastSecrets or dogfood state)
- **Action**: Investigate immediately before proceeding with Brain

### Medium Risk: API Key Missing

If LASTDB_API_KEY is missing:
- **Impact**: Cannot authenticate to /v2 registry
- **Mitigation**: Generate new key via Exemem developer portal
- **Probability**: Low (key likely exists from previous work)
- **Action**: Check org secrets, then LastSecrets

### Low Risk: Manifest Missing

If app manifest is missing:
- **Impact**: Cannot determine app_uuid for release
- **Mitigation**: Create manifest from registration data
- **Probability**: Low (fbrain.app.json exists, just needs brain/lastdb-app.json)
- **Action**: Create manifest file

## Validation Checklist

Before marking this task complete:

- [ ] All required secrets located and documented
- [ ] Secrets added to appropriate GitHub repos/org
- [ ] Workflow tested on at least one app (Brain)
- [ ] First release successfully published to /v2 DEV
- [ ] Release verified via GET /v2/apps/{app_id}/releases
- [ ] Documentation complete for remaining apps

## References

- Implementation PR: [current PR URL]
- DEV Registry: https://y0q3m6vk75.execute-api.us-west-2.amazonaws.com/v2/apps
- Workflow: .github/workflows/publish-app-v2-dev.yml
- Integration Guide: docs/app-v2-registry-publish-dev.md
- Brain Integration: docs/brain-ci-workflow-integration.md
- Example Workflow: examples/brain-ci-required-with-v2-publish.yml
