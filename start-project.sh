#!/bin/sh

set -e  # Exit on error

# --------------------------------------
# ✅ Parse CLI Arguments
# --------------------------------------
FORWARD_ARGS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pv|--no-tailwind|--ua-template) FORWARD_ARGS="$FORWARD_ARGS $1" ;;
    *) echo ""; echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# --------------------------------------
# 📥 Pull supporting files if missing
# --------------------------------------
[ ! -f .github/workflows/build.yaml ] && \
    curl -sSL --create-dirs -o .github/workflows/build.yaml https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/master/build.yaml

[ ! -f .git/hooks/pre-commit ] && \
    curl -sSL --create-dirs -o .git/hooks/pre-commit https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/master/laravel-hooks/pre-commit && chmod +x .git/hooks/pre-commit

[ ! -f docker-compose.yaml ] && \
    curl -sSL -o docker-compose.yaml https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/master/docker-compose.yaml

[ ! -f deploy-plan.json ] && \
    curl -sSL -o deploy-plan.json https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/master/deploy-plan.json

# --------------------------------------
# 🗂️ Handle PV Option
# --------------------------------------
if echo "$FORWARD_ARGS" | grep -qw -- --pv; then
	curl https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/master/add-pv.sh --create-dirs -o add-pv.sh
	chmod +x add-pv.sh
	./add-pv.sh
	rm add-pv.sh
fi

# --------------------------------------
# 🐳 Always generate Dockerfile.dev from API
# --------------------------------------
curl -X POST -d @deploy-plan.json \
     -H "Content-Type: application/json" -H "AUTH: $AUTH" \
     https://build-dockerfile-api.oitapps.ua.edu/api/docker/build-dev > Dockerfile.dev

# --------------------------------------
# 🐳 Rebuild Container
# --------------------------------------
docker stop app || true
docker rm app || true

if command -v docker-compose >/dev/null 2>&1; then
    docker-compose up -d --build
else
    docker compose up -d --build
fi

# --------------------------------------
# 🚀 Run Laravel provisioning inside container
# --------------------------------------
if [ ! -d app ] || [ ! -d vendor ] || [ ! -d node_modules ]; then
    curl -sSL -o laravel-app.sh https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/laravel-app.sh
    chmod +x laravel-app.sh
    docker exec -it app ./laravel-app.sh $FORWARD_ARGS
    rm laravel-app.sh
fi

# --------------------------------------
# 🔧 Run npm dev server in background
# --------------------------------------
echo ""
echo "Running npm run dev in background..."
docker exec -d app npm run dev
