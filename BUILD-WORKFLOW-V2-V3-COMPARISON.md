# Laravel Build Workflow: v2 vs v3 Comparison

A reference for how v2 and v3 work, what lives where, and how production governance fits together.

---

## Executive Summary

Both v2 and v3 use the same **deployment model**:

- **TEST** — push/merge to `test` → automatic deploy
- **PROD** — tag `vX.Y.Z` on current `prod` HEAD → deploy + GitHub Release
- **PROD branch updates** — governed by **branch protection** (PR required), not by the workflow itself

The main difference is **architecture**, not deploy behavior:

| | v2 | v3 |
|---|---|---|
| **Caller workflow** | 61 lines, 4 jobs, orchestration in each app | 18 lines, 1 job, thin wrapper |
| **Reusable workflow** | Build + GitOps only; caller passes `branch` | Validate + build + GitOps + release; caller passes `repository` only |
| **Prod release** | Created twice on tag push (bug) | Created once via `release.yml` |
| **Validation** | Tag checks in caller only | All trigger validation in reusable workflow |

---

## Three-Layer Architecture

Both versions use the same three layers:

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: Template (public-deploy-scripts)                      │
│    build-v2.yaml  or  build-v3.yaml                             │
└────────────────────────────┬────────────────────────────────────┘
                             │ install / copy
┌────────────────────────────▼────────────────────────────────────┐
│  Layer 2: App repo (.github/workflows/)                         │
│    build-v2.yaml / build-v3.yaml                                │
│    + restart-app.yml, sync-main.yml (companions)                │
└────────────────────────────┬────────────────────────────────────┘
                             │ uses: @main
┌────────────────────────────▼────────────────────────────────────┐
│  Layer 3: Shared reusable (ua-app-images/build-laravel-app-image)│
│    build-deploy-app-v2.yml  or  build-deploy-app-v3.yml         │
│    + release.yml, restart-app.yml, lint.yml                     │
└─────────────────────────────────────────────────────────────────┘
```

| Layer | Location | Role |
|---|---|---|
| **Template** | `OIT-Development-Team/public-deploy-scripts/` | Canonical copy installed into app repos |
| **App caller** | `{app}/.github/workflows/build-v2.yaml` or `build-v3.yaml` | Triggers + delegates to shared reusable workflow |
| **Reusable** | `ua-app-images/build-laravel-app-image/.github/workflows/` | Shared build, validate, GitOps, release logic |

---

## Layer 2: App Caller Workflows

### Triggers — identical in v2 and v3

```yaml
on:
  push:
    branches: [test]
    tags: [v*]
  workflow_dispatch:
```

| Event | v2 | v3 |
|---|---|---|
| Push to `test` | Runs | Runs |
| Push to `prod` | Nothing | Nothing |
| Push to `main`/feature | Nothing | Nothing |
| Push tag `v1.2.3` | Runs (if on prod HEAD) | Runs (if on prod HEAD) |
| Manual dispatch | Runs | Runs |

### Jobs — where they diverge

**v2 caller** (`build-v2.yaml`) — 4 jobs, ~61 lines:

| Job | When it runs | What it does |
|---|---|---|
| `validate-prod-tag` | Tag push only | Checks semver format + tag SHA == `prod` HEAD |
| `build-test` | Branch push | Calls reusable v2 with `branch: test` |
| `build-prod` | Tag push (after validate) | Calls reusable v2 with `branch: prod` |
| `release` | Tag push (after build-prod) | Calls `release.yml` |

**v3 caller** (`build-v3.yaml`) — 1 job, ~18 lines:

| Job | When it runs | What it does |
|---|---|---|
| `deploy` | Any allowed trigger | Calls reusable v3 with `repository` only |

### v2 caller example

```yaml
jobs:
  validate-prod-tag:
    if: github.ref_type == 'tag'
    runs-on: ubuntu-latest
    steps:
      # ... tag format + prod HEAD checks ...

  build-test:
    if: github.ref_type == 'branch'
    uses: ua-app-images/build-laravel-app-image/.github/workflows/build-deploy-app-v2.yml@main
    with:
      repository: ${{ github.repository }}
      branch: test
    secrets: inherit

  build-prod:
    needs: validate-prod-tag
    if: github.ref_type == 'tag'
    uses: ua-app-images/build-laravel-app-image/.github/workflows/build-deploy-app-v2.yml@main
    with:
      repository: ${{ github.repository }}
      branch: prod
    secrets: inherit

  release:
    needs: build-prod
    uses: ua-app-images/build-laravel-app-image/.github/workflows/release.yml@main
    with:
      repository: ${{ github.repository }}
    secrets: inherit
```

### v3 caller example

```yaml
jobs:
  deploy:
    uses: ua-app-images/build-laravel-app-image/.github/workflows/build-deploy-app-v3.yml@main
    with:
      repository: ${{ github.repository }}
    secrets: inherit
```

---

## Layer 3: Reusable Workflows

### Inputs

| Input | v2 reusable | v3 reusable |
|---|---|---|
| `repository` | Required (full name) | Required (full name) |
| `branch` | Required (`test` or `prod`) | **Removed** — derived from event |

### Jobs

| Job | v2 reusable | v3 reusable |
|---|---|---|
| `validate` | — | Resolves test vs prod; validates tags |
| `build-app` | Checkout `inputs.branch` | Checkout `needs.validate.outputs.deploy_branch` |
| `update-gitops-folder` | Uses `inputs.branch` for paths | Uses `deploy_branch` output |
| `release` | Inline `softprops/action-gh-release` | Calls `release.yml` (single path) |

### v2 reusable flow

```
App build-v2.yaml
  ├── validate-prod-tag (tags only, in caller)
  ├── build-deploy-app-v2.yml (branch=test or prod)
  │     ├── build-app
  │     ├── update-gitops
  │     └── softprops release  ← duplicate
  └── release.yml              ← duplicate on prod tags
```

### v3 reusable flow

```
App build-v3.yaml
  └── build-deploy-app-v3.yml
        ├── validate (all triggers)
        ├── build-app
        ├── update-gitops
        └── release.yml (prod tags only, once)
```

---

## Example App Repos

### v2 adopter: box-optin

| File | Purpose |
|---|---|
| `build-v2.yaml` | Deploy orchestration (4 jobs) |
| `build.yaml` | Legacy v1 (still present — should be removed) |
| `restart-app.yml` | Manual Vault secret resync + pod restart |
| `sync-main.yml` | Resets `main` to match `prod` after prod merges |

Installed via `install-workflows.sh` (currently installs v2 bundle).

### v3 adopter: laravel-test

| File | Purpose |
|---|---|
| `build-v3.yaml` | Thin deploy caller (1 job) |
| `restart-app.yml` | Manual Vault secret resync + pod restart |

Legacy `build.yaml` (v1) removed to avoid double-runs.

---

## Deployment Behavior (Same in v2 and v3)

### TEST environment

```
Developer merges to test → build workflow runs → Docker :test → GitOps test/ → Argo CD deploys
```

- Image: `uadevelopment/{app-name}:test`
- GitOps path: `OIT-GITOPS/test-cluster/applications/test/{app-name}/`

### PROD environment

```
Developer merges PR to prod → prod branch updated (no deploy)
Someone tags prod HEAD     → build workflow runs → Docker :vX.Y.Z → GitOps prod/ → Release
```

- Image: `uadevelopment/{app-name}:v1.2.3`
- GitOps path: `OIT-GITOPS/test-cluster/applications/prod/{app-name}/`

### Governance model (branch protection + tags)

Production governance uses two layers:

**Layer 1 — GitHub branch protection (who can change `prod`):**

- Normal developers cannot push directly to `prod`
- Code reaches `prod` via approved/merged PRs
- Admins may bypass protection (process: still use PRs)

**Layer 2 — Build workflow (what triggers a deploy):**

- Merge/push to `prod` does **not** deploy
- Only a semver tag (`vX.Y.Z`) on current `prod` HEAD triggers prod deploy
- Tag on wrong commit fails validation

| Control | Enforced by | v2 | v3 |
|---|---|---|---|
| Devs can't push directly to `prod` | Branch protection | Yes (org setting) | Yes (org setting) |
| Code on `prod` came via PR | Branch protection + process | Indirect | Indirect |
| Prod deploy requires semver tag | Workflow | Yes | Yes |
| Tag must be on current `prod` HEAD | Workflow | Yes | Yes |
| PR approval checked in workflow | — | **No** | **No** |

**Takeaway:** PR approval is enforced by **protected branches**, not by the build workflow. The workflow adds an intentional **tag gate** before anything reaches production.

---

## Build Pipeline (Same in v2 and v3 reusable)

Once validation passes, both versions run the same build steps:

1. Checkout app repo (`test` or `prod` branch)
2. Read `deploy-plan.json` (PHP version, npm, DB, ingress, etc.)
3. `composer install --no-dev`
4. `npm ci` + `npm run build` (requires committed `package-lock.json`)
5. Generate or use `Dockerfile`
6. Push image to DockerHub
7. Call build-dockerfile-api for K8s manifests
8. Commit manifests to GitOps repo

**Not included in v2 or v3 build:** Laravel Pint (use optional `lint.yml` separately).

---

## Companion Workflows (Same for v2 and v3 apps)

| Workflow | Trigger | Purpose |
|---|---|---|
| `restart-app.yml` | Manual (`workflow_dispatch`) | Bump ExternalSecret + Deployment annotations → force Vault resync and pod restart |
| `sync-main.yml` | Push to `prod` | Force-reset `main` branch to match `prod` |
| `lint.yml` | Push to any branch (optional) | Pint / lint checks |

These are **separate** from the build workflow by design — secret resync should not require a full image rebuild.

---

## v2 → v3: What Changed vs What Didn't

### Changed

| Area | v2 | v3 |
|---|---|---|
| Caller size | ~61 lines, 4 jobs | ~18 lines, 1 job |
| Orchestration location | Split between caller + reusable | Consolidated in reusable |
| Reusable `branch` input | Required from caller | Removed; auto-resolved |
| Prod GitHub Release | **Twice** (inline + `release.yml`) | **Once** (`release.yml` only) |
| Test trigger validation | Implicit (caller `if` only) | Explicit (`ref_name` must be `test`) |
| `workflow_dispatch` from wrong branch | Could deploy test while on `main` | Fails with clear error |
| GitOps job debug steps | PWD, cat manifests, git status | Removed |

### Unchanged

| Area | v2 | v3 |
|---|---|---|
| Deploy triggers | push `test`, tag `v*` | Same |
| Prod = tag on prod HEAD | Yes | Yes |
| Push to `prod` alone deploys | No | No |
| Docker tagging | `:test` or `:vX.Y.Z` | Same |
| GitOps target | `OIT-GITOPS/test-cluster` | Same |
| Required secrets | Org secrets via `secrets: inherit` | Same |
| `package-lock.json` required | Yes | Yes |
| Pint in build | No | No |
| PR approval in workflow | No | No |

---

## Adoption Status

| App / artifact | Version | Notes |
|---|---|---|
| `public-deploy-scripts` template | v2 in `install-workflows.sh`; v3 template added | v3 not yet default installer |
| box-optin, emma-api | v2 | Full v2 caller + companions |
| laravel-test | v3 | Pilot app |
| Most other Laravel apps | v1 (`build.yaml`) | Push-all-branches; merge-to-prod deploys |

---

## Recommendation Summary

**v3 is ready** for the intended model:

- Protected `prod` → PR required for normal developers
- Tag on `prod` HEAD → intentional production release
- No deploy on merge to `prod` alone

**v3 advantages for the org:**

1. Single place to update deploy logic (`build-deploy-app-v3.yml`)
2. Thin, copy-paste-friendly app workflows
3. Fixes duplicate prod release bug in v2
4. Tighter validation and clearer failure modes

**Suggested next steps:**

1. Pilot on `laravel-test` (push workflow files, verify test deploy)
2. Update `install-workflows.sh` to install `build-v3.yaml` instead of `build-v2.yaml`
3. Migrate v2 apps (box-optin, emma-api) and remove legacy `build.yaml` where present
4. Optionally improve validate-step error messages

---

## Quick Reference Card

| I want to… | Action | v2 | v3 |
|---|---|---|---|
| Deploy to TEST | Merge/push to `test` | Auto | Auto |
| Deploy to PROD | Tag `vX.Y.Z` on `prod` HEAD | Manual tag push | Manual tag push |
| Update prod code | PR into `prod` | No deploy | No deploy |
| Resync Vault secrets | Run **Restart App** workflow | Manual | Manual |
| Run Pint/lint | Enable `lint.yml` | Optional | Optional |

---

## File Locations

| File | Repository |
|---|---|
| `build-v2.yaml` | `OIT-Development-Team/public-deploy-scripts` |
| `build-v3.yaml` | `OIT-Development-Team/public-deploy-scripts` |
| `restart-app.yml` | `OIT-Development-Team/public-deploy-scripts` |
| `sync-main.yml` | `OIT-Development-Team/public-deploy-scripts` |
| `install-workflows.sh` | `OIT-Development-Team/public-deploy-scripts` |
| `build-deploy-app-v2.yml` | `ua-app-images/build-laravel-app-image` |
| `build-deploy-app-v3.yml` | `ua-app-images/build-laravel-app-image` |
| `release.yml` | `ua-app-images/build-laravel-app-image` |
