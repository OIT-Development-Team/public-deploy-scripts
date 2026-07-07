#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_DIR=".github/workflows"
BASE_URL="https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/refs/heads/master"

FILES=(
  build-v2.yaml
  #lint.yml
  restart-app.yml
  #tests.yml
  sync-main.yml
)

echo "Installing shared GitHub workflows..."

mkdir -p "$WORKFLOW_DIR"

# Remove existing workflows
find "$WORKFLOW_DIR" -type f \( -name "*.yml" -o -name "*.yaml" \) -delete

# Download workflows
for file in "${FILES[@]}"; do
  echo "Downloading $file"
  curl -fsSL "$BASE_URL/$file" -o "$WORKFLOW_DIR/$file"
done

echo "✅ Workflows installed."
