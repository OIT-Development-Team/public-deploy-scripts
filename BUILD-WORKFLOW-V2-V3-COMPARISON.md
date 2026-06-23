# Laravel Build Workflow: v1 vs v2 vs v3

How each generation works, what lives where, and why v3 is the target — including honest gaps.

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
- **Pint:** removed from deploy; optional separate `lint.yml` (rarely installed)
- **Tests:** none in deploy path
- **Prod release:** yes — but **created twice** on tag push (known bug)
- **sync-main:** separate workflow on every `prod` push
- **Image tags:** `uadevelopment/{app}:test` or `:v1.2.3`

### v3 — new standard (laravel-test pilot)

- **Prod deploy:** same tag-gated model as v2
- **Test deploy:** push to `test`
- **App workflow:** ~18 lines, 1 job — passes `repository` only
- **Triggers on:** push to `test`, semver tags, manual dispatch
- **Pint / lint:** check-only gate before build (never auto-commits)
- **Tests:** conditional gate before build (skips when project isn't CI-ready)
- **Prod release:** once, via shared `release.yml`
- **sync-main:** built into reusable workflow; runs after successful prod tag release
- **Image tags:** same as v2
- **Onboarding:** `start-project.sh` installs `build-v3.yaml` + `restart-app.yml`

**Headline:** v2 and v3 share the same deployment *intent*. v1 is the outlier — merge to prod deploys. v3 combines v2's governance with v1's caller simplicity and adds quality gates.

---

## How the Pieces Connect

```
public-deploy-scripts          app repo                    build-laravel-app-image
(template)                     (caller)                    (reusable)

build-v3.yaml  ──copy──►  .github/workflows/build-v3.yaml
restart-app.yml           .github/workflows/restart-app.yml
                               │
                               └── uses ──► build-deploy-app-v3.yml
                                            ├── lint.yml
                                            ├── tests.yml
                                            ├── release.yml
                                            └── (sync-main inline)
```

**Three layers:**

- **Template** (`public-deploy-scripts`) — canonical YAML copied into app repos
- **App caller** (`{app}/.github/workflows/`) — defines *when* deploy runs
- **Reusable** (`ua-app-images/build-laravel-app-image`) — shared validate, lint, tests, build, GitOps, release

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
- v3: deploy to TEST (after lint + tests pass)

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
- v3: validate → lint → tests → build → GitOps → Release → sync-main

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

Requires caller to pass `branch: test` or `branch: prod`. No lint or tests in deploy path.

### v3 — `build-deploy-app-v3.yml`

```
validate          → resolve test vs prod; reject bad triggers
lint       ──┐
tests      ──┴→ parallel quality gates (tests skip when not CI-ready)
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
- **v3:** PHP 8.5 default; lockfile required; image tag `{ref}`; lint/tests before build

---

## Quality Gates

### v1 — Pint auto-commit on every push

Runs on all branch pushes. Can commit `"style: Apply Laravel Pint fixes"` back to the app repo from CI. No frontend lint. No tests.

### v2 — none in deploy path

Optional standalone `lint.yml` on all branches — rarely installed. Pre-commit hook is the main defense.

### v3 — lint + tests block deploy

**Lint** (always on deploy triggers): `composer lint`, `npm run format`, `npm run lint`. Check-only — never commits.

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

**`restart-app.yml`** — all versions. Manual dispatch. Forces Vault secret resync + pod restart. Not part of deploy.

**sync-main**

- v1: not used
- v2: separate workflow; runs on `prod` push
- v3: built into reusable; runs after successful prod tag release

**Standalone `lint.yml` / `tests.yml`**

- v2: optional, installed separately
- v3: not needed in app repos — logic lives inside v3 reusable

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
9. **Simple onboarding** — `start-project.sh` installs the v3 bundle

---

## Where v3 Is Not Superior

These are trade-offs, not bugs:

**Slower deploys** — lint and tests run before every test push and prod tag. v1/v2 go straight to build.

**No MS Teams notifications** — v1 posted to Teams on deploy. v2/v3 do not. Add back as an optional job if ops wants it.

**Stricter lint** — v1 auto-fixed from CI. v3 fails and expects local/pre-commit fixes.

**No lint on feature branches** — v1 ran Pint on every push; v2 could with optional `lint.yml`. v3 lint only runs on deploy triggers (test push, prod tag).

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

**Resync Vault secrets** — run **Restart App** workflow manually (all versions).

**Sync `main` to match prod**

- v1: manual
- v2: automatic on `prod` push
- v3: automatic after prod tag release succeeds

**Run lint in CI**

- v1: automatic on every push (auto-commit)
- v2: optional separate `lint.yml`
- v3: gate before every deploy (check-only)

**Run tests in CI**

- v1 / v2: not in deploy path
- v3: gate before deploy when project is CI-ready

---

## Adoption Today

- **Most OIT Laravel apps** — v1 (`build.yaml`, merge-to-prod)
- **box-optin, emma-api** — v2 (some still have legacy `build.yaml` — remove to avoid double-runs)
- **laravel-test** — v3 pilot (`@test` ref on reusable)
- **public-deploy-scripts** — v3 templates; `start-project.sh` installs bundle from `test` branch
- **build-laravel-app-image** — all three reusables coexist; v3 on `test` during pilot

---

## Migration Checklist (v1 or v2 → v3)

1. Remove legacy `build.yaml` if present
2. Install `build-v3.yaml` + `restart-app.yml`
3. Commit `package-lock.json` if missing
4. Confirm branch protection on `prod`
5. Verify test deploy on push to `test`
6. Verify prod deploy on tag + GitHub Release + sync-main

---

## File Locations

**public-deploy-scripts**

- `build.yaml` — v1 template (legacy on stable)
- `build-v2.yaml` — v2 template
- `build-v3.yaml` — v3 template
- `restart-app.yml` — all versions
- `start-project.sh` — installs v3 bundle for new projects

**ua-app-images/build-laravel-app-image**

- `build-deploy-app.yml` — v1 reusable
- `build-deploy-app-v2.yml` — v2 reusable
- `build-deploy-app-v3.yml` — v3 reusable
- `lint.yml`, `tests.yml`, `release.yml` — shared sub-workflows called by v3
