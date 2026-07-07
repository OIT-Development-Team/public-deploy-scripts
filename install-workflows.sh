#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_DIR=".github/workflows"
BASE_URL="https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/refs/heads/main"

FILES=(
  build-v3.yaml
  refresh-vault-secrets.yaml
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
