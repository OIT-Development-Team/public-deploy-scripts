# Laravel Build Workflow: v1 vs v2 vs v3

Reference for deployment models, file layout, and migration. Covers v1 (legacy), v2 (tag-gated prod), and v3 (current pilot target).

---

## At a Glance

### v1 — legacy (most production apps today)

- **Prod deploy:** push or merge to `prod` → ships immediately
- **Test deploy:** push to `test`
- **App workflow:** ~18 lines, 1 job, passes `branch: ${{ github.ref_name }}`
- **Triggers on:** every branch push (Pint may run on feature branches; build only on `test`/`prod`)
- **Pint:** runs in deploy path and **auto-commits** fixes back to the repo
- **Tests:** none in CI deploy path
- **Prod release:** no GitHub Release; MS Teams notification on deploy
- **Image tags:** `uadevelopment/{app}:prod-847` (branch + run number)

### v2 — tag-gated prod (box-optin, emma-api)

- **Prod deploy:** tag `vX.Y.Z` on current `prod` HEAD only
- **Test deploy:** push to `test`
- **App workflow:** ~61 lines, 4 jobs (validate, build-test, build-prod, release)
- **Triggers on:** push to `test`, semver tags, manual dispatch
- **Pint:** removed from deploy; optional standalone workflow (legacy `lint.yml`) — rarely installed
- **Tests:** none in deploy path
- **Prod release:** yes — but **created twice** on tag push (known bug)
- **sync-main:** separate workflow on every `prod` push
- **Vault refresh:** manual `restart-app.yml` caller → reusable `refresh-vault-secrets.yml` (renamed from `restart-app.yml`)
- **Image tags:** `uadevelopment/{app}:test` or `:v1.2.3`

### v3 — new standard (laravel-test pilot)

- **Prod deploy:** same tag-gated model as v2
- **Test deploy:** push to `test`
- **App workflow:** ~18 lines, 1 job — passes `repository` only
- **Triggers on:** push to `test`, semver tags, manual dispatch
- **Pint / frontend checks:** Pint check-only gate before build (never auto-commits); optional npm format/lint if defined
- **Tests:** conditional gate before build (skips when project isn't CI-ready)
- **Prod release:** once, via shared `release.yml`
- **sync-main:** built into reusable workflow; runs after successful prod tag release
- **Image tags:** same as v2
- **Vault refresh:** manual workflow; app caller `refresh-vault-secrets.yaml` → reusable `refresh-vault-secrets.yml`
- **Onboarding:** `start-project.sh` removes legacy workflows, then installs `build-v3.yaml` + `refresh-vault-secrets.yaml`

**Headline:** v2 and v3 share the same deployment *intent*. v1 is the outlier — merge to prod deploys. v3 combines v2's governance with v1's caller simplicity and adds quality gates.

---

## How the Pieces Connect

```
public-deploy-scripts          app repo                         build-laravel-app-image
(template)                     (caller)                         (reusable)

build-v3.yaml  ──copy──►  .github/workflows/build-v3.yaml ──uses──► build-deploy-app-v3.yml@test
                               │                                      ├── pint.yml
                               │                                      ├── tests.yml
                               │                                      ├── release.yml
                               │                                      └── sync-main (inline job)
                               │
refresh-vault-secrets.yaml     refresh-vault-secrets.yaml ──uses──► refresh-vault-secrets.yml@test
(copy)                         (manual dispatch only;               (separate from deploy)
                                not part of build-v3)
```

**Three layers:**

- **Template** (`public-deploy-scripts`) — canonical YAML copied into app repos
- **App caller** (`{app}/.github/workflows/`) — defines *when* a workflow runs
- **Reusable** (`ua-app-images/build-laravel-app-image`) — shared build, quality gates, GitOps, release logic

**Pilot refs:** v3 templates and `laravel-test` call reusables at `@test` (e.g. `build-deploy-app-v3.yml@test`). After fleet promotion, switch callers to `@main`.

**`start-project.sh` (v3 onboarding):** on each run, removes legacy app workflows (`build.yaml`, `build-v2.yaml`, `sync-main.yml`, `lint.yml`, `tests.yml`, `restart-app.yml`), then fetches `build-v3.yaml` and `refresh-vault-secrets.yaml` if missing. Installs `laravel-hooks/pre-commit` → `.git/hooks/pre-commit` if missing (does not overwrite an existing hook).

---

## Deployment Models

### v1 — merge-to-prod

```
Push ANY branch
  ├── test branch  → deploy TEST
  ├── prod branch  → deploy PROD  ⚠ immediate
  └── other        → Pint may run; no deploy
```

No tag gate. Branch protection is the only guard before prod code changes; the workflow does not add a release step.

### v2 and v3 — tag-gated prod

```
Push to test              → deploy TEST
Push/merge to prod        → nothing (code only)
Tag vX.Y.Z on prod HEAD   → deploy PROD + GitHub Release
```

Someone must intentionally tag current `prod` HEAD to ship. Invalid tags or tags on the wrong commit fail validation.

**Governance note:** PR approval is enforced by **GitHub branch protection**, not inside any build workflow.

---

## What Happens on Each Event

**Push to `test`**

- v1: deploy to TEST
- v2: deploy to TEST
- v3: deploy to TEST (after Pint + tests pass)

**Push/merge to `prod`**

- v1: deploy to PROD immediately
- v2: nothing (v2 `sync-main.yml` may reset `main` to match `prod`)
- v3: nothing

**Push to `main` or a feature branch**

- v1: workflow runs; Pint may auto-commit; no deploy unless ref is test/prod
- v2: nothing
- v3: nothing

**Tag `v1.2.3` on prod HEAD**

- v1: runs if caller receives tag ref (unusual in v1 setups)
- v2: validate → build prod → GitHub Release (×2)
- v3: validate → pint → tests → build → GitOps → Release → sync-main

**Manual workflow dispatch**

- v1: runs on current ref
- v2: can deploy test from wrong branch (loose)
- v3: fails unless ref is `test` or a valid prod tag

---

## Reusable Workflow: What Each Version Runs

### v1 — `build-deploy-app.yml`

```
pint-fix          → Pint + auto-commit to app repo
build-app         → Docker build/push (test or prod refs only)
update-gitops     → commit manifests
MS Teams notify
```

Requires caller to pass `branch`. Uses older Actions. Optional `package-lock.json`. Extra secret: `MSTEAMS_WEBHOOK`.

### v2 — `build-deploy-app-v2.yml` (+ caller orchestration)

```
Caller: validate-prod-tag | build-test | build-prod | release.yml

Reusable:
  build-app         → Docker build/push
  update-gitops     → commit manifests
  softprops release → duplicate with caller release job on tags
```

Requires caller to pass `branch: test` or `branch: prod`. No Pint or tests in deploy path.

### v3 — `build-deploy-app-v3.yml`

```
validate          → resolve test vs prod; reject bad triggers
pint       ──┐
tests      ──┴→ parallel quality gates (Pint check + optional npm; tests skip when not CI-ready)
build-app         → Docker build/push
update-gitops     → commit manifests
release           → prod tags only, once
sync-main         → prod tags only, after release
```

Caller passes `repository` only. Branch derived from the triggering event.

---

## Build Pipeline (shared core)

All versions, once past gates:

1. Checkout app repo
2. Read `deploy-plan.json`
3. `composer install --no-dev`
4. npm install/build (when `run_npm` is true)
5. Generate or use `Dockerfile`
6. Push to DockerHub
7. Generate K8s manifests via build-dockerfile-api
8. Commit to GitOps (`OIT-GITOPS/test-cluster`)

**Build differences worth knowing:**

- **v1:** PHP 8.4 default; lockfile optional; image tag `{branch}-{run#}`; older Actions
- **v2:** lockfile required (`npm ci`); image tag `{ref}`; no Teams webhook
- **v3:** PHP 8.5 default; lockfile required; image tag `{ref}`; Pint/tests before build

---

## Quality Gates

### v1 — Pint auto-commit on every push

Runs on all branch pushes. Can commit `"style: Apply Laravel Pint fixes"` back to the app repo from CI. No frontend lint. No tests.

### v2 — none in deploy path

Optional standalone `lint.yml` in the app repo (all-branch push) — rarely installed. Pre-commit hook is the main defense.

### v3 — Pint + tests block deploy

**Pint job** (`pint.yml`, `workflow_call` only — not triggered on feature branches): `./vendor/bin/pint --test`, or `composer lint:check` when defined. Optional npm `format` / `lint` scripts if the app defines them. Check-only — never commits.

**Tests** (skip cleanly when not ready):

- Skip if no `.env.example`
- Skip if `run_npm: false` in deploy-plan
- Skip if no `*Test.php` files under `tests/`
- Skip if no Pest or PHPUnit in `composer.json` require-dev
- When running: prefers Pest, falls back to PHPUnit
- Failing tests block deploy

Pre-commit hook (from `start-project.sh`) is still the first line of defense.

---

## Companion Workflows

These are **separate from deploy** — not jobs inside `build-deploy-app-v3.yml`.

### Refresh Vault Secrets & Restart

Manual `workflow_dispatch` only. Bumps GitOps annotations so External Secrets Operator re-fetches from Vault and pods restart. Does **not** rebuild the Docker image.

| | App caller file | Reusable |
|---|---|---|
| **v3** | `refresh-vault-secrets.yaml` | `refresh-vault-secrets.yml` |
| **v2** | `restart-app.yml` (legacy filename) | `refresh-vault-secrets.yml` (was `restart-app.yml`) |
| **v1** | not standard; add manually if needed | same reusable when installed |

GitHub UI name: **Refresh Vault Secrets & Restart**.

### sync-main

- v1: not used
- v2: separate app workflow; runs on `prod` push
- v3: inline job in `build-deploy-app-v3.yml`; runs after successful prod tag release

### Optional standalone quality workflows (v1/v2 only)

Historically, some v2 apps installed a separate app-repo `lint.yml` (all-branch push) or `tests.yml`. **v3 does not use these** — Pint and tests run inside the deploy reusable via `pint.yml` and `tests.yml` (`workflow_call` only, invoked by `build-deploy-app-v3.yml`).

---

## Why v3 Is Superior

1. **Correct prod governance** — inherits v2's tag gate; fixes v1's merge-to-prod problem
2. **Single source of truth** — one reusable file to update for all apps
3. **Thin app callers** — ~18 lines; no per-app orchestration drift
4. **Fixes v2 bugs** — duplicate GitHub Release; loose manual dispatch
5. **Explicit validation** — rejects unsupported triggers with clear errors
6. **Quality gates without auto-commit** — blocks bad deploys; doesn't rewrite repos from CI
7. **Better sync-main timing** — after release, not on every prod merge before tag
8. **Modern build hygiene** — lockfile required, current Actions, PHP 8.5 default
9. **Simple onboarding** — `start-project.sh` removes legacy workflows and installs the v3 bundle

---

## Where v3 Is Not Superior

These are trade-offs, not bugs:

**Slower deploys** — Pint and tests run before every test push and prod tag. v1/v2 go straight to build.

**No MS Teams notifications** — v1 posted to Teams on deploy. v2/v3 do not. Add back as an optional job if ops wants it.

**Stricter Pint** — v1 auto-fixed from CI. v3 fails and expects local/pre-commit fixes.

**No Pint on feature branches** — v1 ran Pint on every push; v2 could with optional standalone workflow (legacy `lint.yml`). v3 Pint only runs on deploy triggers (test push, prod tag).

**Tests can block shipping** — when a project is CI-ready, failing tests stop deploy. v1/v2 never ran tests in the deploy path.

**Migration effort** — most apps still on v1; requires workflow swap and removing old `build.yaml`.

**Lockfile required** — v1 tolerated missing `package-lock.json`. v2/v3 fail without it.

**sync-main timing change** — v2 synced on prod push; v3 syncs after tag release. v3 timing matches what's actually in production.

**Pilot maturity** — v3 validated on laravel-test; not yet fleet-wide on `stable`.

---

## Common Tasks

**Deploy to TEST** — push or merge to `test` (all versions).

**Deploy to PROD**

- v1: push or merge to `prod`
- v2 / v3: tag `vX.Y.Z` on current `prod` HEAD

**Update prod code without deploying**

- v1: not really possible — merge deploys
- v2 / v3: merge PR into `prod`; deploy only when tagged

**Resync Vault secrets** — run **Refresh Vault Secrets & Restart** manually (v2/v3 when installed).

**Sync `main` to match prod**

- v1: manual
- v2: automatic on `prod` push
- v3: automatic after prod tag release succeeds

**Run Pint in CI**

- v1: automatic on every push (auto-commit)
- v2: optional standalone workflow (legacy filename `lint.yml`)
- v3: `pint` job before every deploy — `./vendor/bin/pint --test` (check-only)

**Run tests in CI**

- v1 / v2: not in deploy path
- v3: gate before deploy when project is CI-ready

---

## Adoption Today

- **Most OIT Laravel apps** — v1 (`build.yaml`, merge-to-prod)
- **box-optin, emma-api** — v2 (`build-v2.yaml`, caller `restart-app.yml`; update reusable ref to `refresh-vault-secrets.yml` after rename)
- **laravel-test** — v3 pilot (`@test` ref on reusable)
- **public-deploy-scripts** — v3 templates; `start-project.sh` installs bundle from `test` branch
- **build-laravel-app-image** — all three reusables coexist; v3 on `test` during pilot

---

## Migration Checklist (v1 or v2 → v3)

1. Remove legacy app workflows: `build.yaml`, `build-v2.yaml`, `sync-main.yml`, `lint.yml`, `tests.yml`, `restart-app.yml` (or run `start-project.sh` / `laravel-app`, which removes them automatically)
2. Install `build-v3.yaml` + `refresh-vault-secrets.yaml` (from `public-deploy-scripts/test`)
3. Confirm callers use `@test` during pilot, then `@main` after promotion
4. Commit `package-lock.json` if missing
5. Confirm branch protection on `prod`
6. Verify test deploy on push to `test` (`validate → pint → tests → build-app → …`)
7. Verify prod deploy on tag + GitHub Release + sync-main
8. Verify **Refresh Vault Secrets & Restart** manual workflow (test environment)

---

## File Locations

**public-deploy-scripts**

| Branch | What it ships |
|---|---|
| **`test`** (v3 pilot) | `build-v3.yaml`, `refresh-vault-secrets.yaml`, `start-project.sh`, `laravel-app.sh`, `laravel-hooks/pre-commit`, `deploy-plan.json`, `docker-compose.yaml` |
| **`stable`** (legacy) | `build.yaml` (v1), older templates — not used by current `start-project.sh` on `test` |

**App repo (v3)**

- `.github/workflows/build-v3.yaml` — deploy caller
- `.github/workflows/refresh-vault-secrets.yaml` — manual vault refresh caller
- `.git/hooks/pre-commit` — installed from template (local only, not committed)

**ua-app-images/build-laravel-app-image**

| Reusable | Used by |
|---|---|
| `build-deploy-app.yml` | v1 |
| `build-deploy-app-v2.yml` | v2 |
| `build-deploy-app-v3.yml` | v3 deploy orchestration |
| `pint.yml` | v3 deploy (`workflow_call` from v3 only) |
| `tests.yml` | v3 deploy (`workflow_call` from v3 only) |
| `release.yml` | v3 prod tag releases |
| `refresh-vault-secrets.yml` | manual vault refresh ( **not** part of deploy) |

All v3 reusables coexist on the `test` branch during pilot; v1/v2 reusables remain on `main`.
