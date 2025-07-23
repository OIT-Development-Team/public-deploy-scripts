#!/bin/sh

set -e  # Exit on error

# --------------------------------------
# ✅ Parse CLI Arguments
# --------------------------------------
FORWARD_ARGS=""

# Parse command-line arguments
while [ $# -gt 0 ]; do
	case "$1" in
		--pv|--no-tailwind|--ua-template|--no-ua-template|--windows|--no-windows)
			FORWARD_ARGS="$FORWARD_ARGS $1"
			;;
		*)
			echo ""
			echo "❌ Unknown option: $1"
			exit 1
			;;
	esac
	shift
done

# --------------------------------------
# 📦 Pull Supporting Files
# --------------------------------------
[ ! -f .github/workflows/build.yaml ] && \
	curl -sSL --create-dirs -o .github/workflows/build.yaml  https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/build.yaml

[ ! -f .git/hooks/pre-commit ] && \
	curl -sSL --create-dirs -o .git/hooks/pre-commit https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/laravel-hooks/pre-commit && chmod +x .git/hooks/pre-commit

[ ! -f docker-compose.yaml ] && \
	curl -sSL -o docker-compose.yaml https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/docker-compose.yaml

[ ! -f deploy-plan.json ] && \
	curl -sSL -o deploy-plan.json https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/deploy-plan.json

# --------------------------------------
# 🗂️ Handle PV Option
# --------------------------------------
if echo "$FORWARD_ARGS" | grep -qw -- --pv; then
	curl https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/add-pv.sh --create-dirs -o add-pv.sh
	chmod +x add-pv.sh
	./add-pv.sh
	rm add-pv.sh
fi

# --------------------------------------
# 🧱 Prepare Laravel Provision Script
# --------------------------------------
if [ ! -d app ] && [ ! -f laravel-app.sh ]; then
	curl -sSL -o laravel-app.sh https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/test/laravel-app.sh
	chmod +x laravel-app.sh
fi

# --------------------------------------
# 🐳 Generate Dockerfile.dev from API
# --------------------------------------
curl -X POST -d @deploy-plan.json --header "Content-Type: application/json" -H "AUTH: $AUTH" https://build-dockerfile-api.oitapps-test.ua.edu/api/docker/build-dev > Dockerfile.dev

# --------------------------------------
# 🐳 Rebuild Container
# --------------------------------------
docker stop app || true
docker rm app || true

# Check for Windows by detecting 'OS' environment variable in Bash
if [ "$OS" = "Windows_NT" ]; then
	# Windows environment (Bash)
	if command -v docker-compose >/dev/null 2>&1; then
		docker-compose up -d --build
	else
		docker compose up -d --build
	fi
else
	# Unix-like environment (Linux, macOS)
	if command -v docker-compose >/dev/null 2>&1; then
		docker-compose up -d --build
	else
		docker compose up -d --build
	fi
fi

# --------------------------------------
# 🚀 Run Laravel Provisioning
# --------------------------------------
docker exec -it app ./laravel-app.sh $FORWARD_ARGS

rm laravel-app.sh

echo ""
echo "Running npm run dev in background..."
docker exec -d app npm run dev
