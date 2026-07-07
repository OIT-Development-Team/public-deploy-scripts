#!/usr/bin/env bash
set -euo pipefail

WORKFLOW_DIR=".github/workflows"
LEGACY_FILE="build.yaml"
LEGACY_URL="https://raw.githubusercontent.com/OIT-Development-Team/public-deploy-scripts/stable/build.yaml"

echo "Restoring legacy GitHub workflows..."

mkdir -p "$WORKFLOW_DIR"

# Remove existing workflows
find "$WORKFLOW_DIR" -type f \( -name "*.yml" -o -name "*.yaml" \) -delete

echo "Downloading $LEGACY_FILE"
curl -fsSL "$LEGACY_URL" -o "$WORKFLOW_DIR/$LEGACY_FILE"

echo "✅ Legacy workflows restored."
