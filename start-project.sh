#!/bin/sh
#
# start-project.sh — Local Laravel development entry point
#
# Run this script from your project root to start (or create) a Laravel app in Docker.
# It orchestrates container setup and delegates application provisioning to laravel-app.sh
# inside the container.
#
# Remote resources are fetched when possible so updates are picked up. If a fetch
# fails (e.g. offline), the script falls back to an existing local copy where appropriate.
# deploy-plan.json and docker-compose.yaml are never overwritten once present (project-specific).
# GitHub workflow and pre-commit hook are fetched only when missing.
# add-pv.sh and laravel-app.sh are downloaded when needed and removed after use.
#
# USAGE:
#   ./start-project.sh [OPTIONS]
#
# OPTIONS:
#   --pv              Add persistent volume claims to deploy-plan.json (downloads add-pv.sh; requires network)
#   --no-tailwind     Remove Tailwind from existing projects, or skip it in new projects
#   --add-tailwind    Add Tailwind to existing projects only (new projects get it from the Laravel installer)
#   --ua-template     Download University of Alabama UI component templates (works with new and existing projects)
#
# EXAMPLES:
#   ./start-project.sh
#   ./start-project.sh --pv
#   ./start-project.sh --no-tailwind
#   ./start-project.sh --pv --ua-template
#

ulimit -n 4096
set -e  # Exit on error

# --------------------------------------
# Helpers
# --------------------------------------
# Download URL to dest. On failure, keep/use existing dest if present.
# Exits only when the download fails and no local copy exists.
fetch_or_fallback() {
    url="$1"
    dest="$2"
    label="$3"
    tmp=".fetch.tmp.$$"
    dest_dir=$(dirname "$dest")

    if [ "$dest_dir" != "." ]; then
        mkdir -p "$dest_dir"
    fi

    if curl -sSL -f -o "$tmp" "$url"; then
        mv "$tmp" "$dest"
        echo "✅ Updated $label"
    else
        rm -f "$tmp"
        if [ -f "$dest" ]; then
            echo "⚠️  Could not fetch $label; using existing local copy"
        else
            echo "❌ Could not fetch $label and no local copy exists"
            exit 1
        fi
    fi
}

# Fetch only when dest is missing; never overwrite an existing file (for project-specific config).
fetch_if_missing_or_fallback() {
    url="$1"
    dest="$2"
    label="$3"

    if [ -f "$dest" ]; then
        echo "ℹ️  Using existing $label"
        return 0
    fi

    fetch_or_fallback "$url" "$dest" "$label"
}

# POST deploy-plan.json to the Dockerfile API. Falls back to existing Dockerfile.dev on failure.
fetch_dockerfile_or_fallback() {
    tmp="Dockerfile.dev.tmp.$$"
    # TEST: https://build-dockerfile-api.oitapps-test.ua.edu/api/docker/build-dev
    # STABLE: https://build-dockerfile-api.oitapps.ua.edu/api/docker/build-dev
    if curl -sSL -f -X POST -d @deploy-plan.json \
         -H "Content-Type: application/json" -H "AUTH: $AUTH" \
         -o "$tmp" \
         https://build-dockerfile-api.oitapps-test.ua.edu/api/docker/build-dev; then
        mv "$tmp" Dockerfile.dev
        echo "✅ Updated Dockerfile.dev"
    else
        rm -f "$tmp"
        if [ -f Dockerfile.dev ]; then
            echo "⚠️  Could not fetch Dockerfile.dev; using existing local copy"
        else
            echo "❌ Could not fetch Dockerfile.dev and no local copy exists"
            exit 1
        fi
    fi
}

# Verify a required file exists and is not empty.
require_file() {
    file="$1"
    label="$2"

    if [ ! -f "$file" ]; then
        echo "❌ Required file missing: $label ($file)"
        exit 1
    fi
    if [ ! -s "$file" ]; then
        echo "❌ Required file is empty: $label ($file)"
        exit 1
    fi
}

# Verify Docker CLI, daemon, and Compose are available (macOS, Linux, Windows/WSL).
require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "❌ Docker is not installed or not in your PATH"
        echo "   Install Docker Desktop: https://docs.docker.com/get-docker/"
        exit 1
    fi

    if ! docker info >/dev/null 2>&1; then
        echo "❌ Docker is installed but the daemon is not running"
        echo "   Start Docker Desktop or the Docker service, then try again"
        exit 1
    fi

    if command -v docker-compose >/dev/null 2>&1; then
        COMPOSE="docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        COMPOSE="docker compose"
    else
        echo "❌ Docker Compose is not available"
        echo "   Install Docker Compose or enable the Compose plugin in Docker Desktop"
        exit 1
    fi
}

# --------------------------------------
# Parse CLI arguments (forwarded to laravel-app.sh except --pv)
# --------------------------------------
FORWARD_ARGS=""
LARAVEL_APP_ARGS=""


while [ $# -gt 0 ]; do
  case "$1" in
    --pv|--no-tailwind|--add-tailwind|--ua-template)
      FORWARD_ARGS="$FORWARD_ARGS $1"
      # --pv is handled on the host before the image is built; do not pass it through
      if [ "$1" != "--pv" ]; then
        LARAVEL_APP_ARGS="$LARAVEL_APP_ARGS $1"
      fi
      ;;
    *)
      echo ""
      echo "❌ Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

# True when the project already has a Laravel application tree
EXISTING_APP=false
[ -d app ] && EXISTING_APP=true

# --------------------------------------
# Fetch supporting files (fall back to local copies on network failure)
# deploy-plan.json and docker-compose.yaml are only fetched when missing.
# --------------------------------------
# TEST: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/docker-compose.yaml
# STABLE: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/stable/docker-compose.yaml
fetch_if_missing_or_fallback \
    "https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/docker-compose.yaml" \
    "docker-compose.yaml" \
    "docker-compose.yaml"

# TEST: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/deploy-plan.json
# STABLE: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/stable/deploy-plan.json
fetch_if_missing_or_fallback \
    "https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/deploy-plan.json" \
    "deploy-plan.json" \
    "deploy-plan.json"

# TEST: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/build.yaml
# STABLE: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/stable/build.yaml
fetch_if_missing_or_fallback \
    "https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/build.yaml" \
    ".github/workflows/build.yaml" \
    ".github/workflows/build.yaml"

# TEST: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/laravel-hooks/pre-commit
# STABLE: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/stable/laravel-hooks/pre-commit
fetch_if_missing_or_fallback \
    "https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/laravel-hooks/pre-commit" \
    ".git/hooks/pre-commit" \
    ".git/hooks/pre-commit"
[ -f .git/hooks/pre-commit ] && chmod +x .git/hooks/pre-commit

# --------------------------------------
# Persistent volumes (--pv): download, run on host, then remove (never kept locally)
# --------------------------------------
if echo "$FORWARD_ARGS" | grep -qw -- --pv; then
    rm -f add-pv.sh
    ADD_PV_TMP="add-pv.sh.tmp.$$"
    # TEST: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/add-pv.sh
    # STABLE: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/stable/add-pv.sh
    if curl -sSL -f -o "$ADD_PV_TMP" \
        "https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/add-pv.sh"; then
        mv "$ADD_PV_TMP" add-pv.sh
        chmod +x add-pv.sh
        ./add-pv.sh
        rm -f add-pv.sh
    else
        rm -f "$ADD_PV_TMP" add-pv.sh
        echo ""
        echo "⚠️  Could not fetch add-pv.sh; skipping persistent volume configuration"
    fi
fi

# --------------------------------------
# Generate Dockerfile.dev from deploy-plan (fall back to local copy on failure)
# --------------------------------------
fetch_dockerfile_or_fallback

require_file "docker-compose.yaml" "docker-compose.yaml"
require_file "Dockerfile.dev" "Dockerfile.dev"
require_docker

# --------------------------------------
# Rebuild and start the development container
# --------------------------------------
docker stop app || true
docker rm app || true

if ! $COMPOSE up -d --build; then
    if [ "$EXISTING_APP" = true ]; then
        echo ""
        echo "⚠️  Container build failed; attempting to start with existing image..."
        $COMPOSE up -d
    else
        exit 1
    fi
fi

# --------------------------------------
# Provision or update the Laravel app inside the container
# Download, run, then remove (never kept locally)
# --------------------------------------
LARAVEL_APP_TMP="laravel-app.sh.tmp.$$"
# TEST: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/laravel-app.sh
# STABLE: https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/stable/laravel-app.sh
if curl -sSL -f -o "$LARAVEL_APP_TMP" \
    "https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/laravel-app.sh"; then
    mv "$LARAVEL_APP_TMP" laravel-app.sh
    chmod +x laravel-app.sh
    # shellcheck disable=SC2086
    docker exec -it app ./laravel-app.sh $LARAVEL_APP_ARGS
    rm -f laravel-app.sh
else
    rm -f "$LARAVEL_APP_TMP" laravel-app.sh
    echo ""
    echo "⚠️  Could not fetch laravel-app.sh; skipping Laravel provisioning"
    if [ "$EXISTING_APP" = false ]; then
        echo "❌ Cannot scaffold a new project without laravel-app.sh"
        exit 1
    fi
fi

# --------------------------------------
# Start Vite dev server in the background when enabled in deploy-plan.json
# --------------------------------------
RUN_NPM=$(docker exec app php -r "\$d = json_decode(@file_get_contents('deploy-plan.json'), true); \$val = \$d['build']['run_npm'] ?? \$d['run_npm'] ?? null; if(\$val === null) { echo 'true'; } else { if(\$val === false || \$val === 'false') echo 'false'; else echo 'true'; }")

if [ "$RUN_NPM" = "false" ]; then
    echo ""
    echo "⚠️  Skipping npm run dev (run_npm=false in deploy-plan.json)"
else
    echo ""
    echo "Running npm run dev in background..."
    docker exec -d app npm run dev
fi
 