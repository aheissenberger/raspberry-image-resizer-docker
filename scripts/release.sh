#!/usr/bin/env bash
set -euo pipefail

# Release script for raspberry-image-resizer-docker
# Performs: build artifacts, update formula, commit/push, create or update GitHub release.

shopt -s nullglob || true  # safe on bash; ignored on zsh if invoked via bash explicitly

# Build artifacts (binary + tarball) and update formula version + sha256
./scripts/build-release.sh
node ./scripts/update-formula.js

VER=$(node -p "require('./package.json').version")
TAG="v$VER"
ASSETS=(release/rpi-tool-*.tar.gz)

if [ ${#ASSETS[@]} -eq 0 ]; then
  echo "No release assets found matching release/rpi-tool-*.tar.gz" >&2
  exit 1
fi

echo "Preparing release for version $VER (tag: $TAG)"

git add rpi-image-resizer.rb || true
git commit -m "chore(release): v$VER" || echo "No changes to commit"
git push || echo "Git push skipped (no remote?)"

if command -v gh >/dev/null 2>&1; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG exists, uploading assets (clobber)"
    gh release upload "$TAG" "${ASSETS[@]}" --clobber
  else
    echo "Creating release $TAG"
    gh release create "$TAG" "${ASSETS[@]}" -t "rpi-tool v$VER" -n "Self-contained binary with embedded Dockerfile/worker. Auto-builds Docker image on first run."
  fi
else
  echo "GitHub CLI (gh) not found; skipping release creation/upload." >&2
fi

echo "Release script completed for $TAG"