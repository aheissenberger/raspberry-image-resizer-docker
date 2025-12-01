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

# Stage and commit formula changes
git add rpi-image-resizer.rb
git commit -m "chore(release): v$VER" || echo "No changes to commit"

# Push commits first
git push origin HEAD

# Create and push tag
git tag -a "$TAG" -m "Release version $VER" -f
git push origin "$TAG" -f

# Create GitHub release
if command -v gh >/dev/null 2>&1; then
  echo "Creating release $TAG"
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG exists, uploading assets"
    gh release upload "$TAG" "${ASSETS[@]}" --clobber
  else
    echo "Creating new release $TAG"
    gh release create "$TAG" "${ASSETS[@]}" \
      -t "rpi-tool v$VER" \
      -n "Self-contained binary with embedded Dockerfile/worker. Auto-builds Docker image on first run."
  fi
else
  echo "GitHub CLI (gh) not found; skipping release creation/upload." >&2
fi

echo ""
echo "✓ Release $TAG published successfully!"

# Update Homebrew tap formula using GitHub API
if command -v gh >/dev/null 2>&1; then
  echo ""
  echo "Updating Homebrew tap formula..."
  
  TAP_REPO="aheissenberger/homebrew-rpi-tools"
  FORMULA_PATH="Formula/rpi-image-resizer.rb"
  FORMULA_CONTENT=$(cat rpi-image-resizer.rb)
  
  # Get current file SHA (required for update)
  CURRENT_SHA=$(gh api "repos/$TAP_REPO/contents/$FORMULA_PATH" --jq '.sha' 2>/dev/null || echo "")
  
  if [ -n "$CURRENT_SHA" ]; then
    # Update existing file
    echo "Updating formula in $TAP_REPO..."
    gh api "repos/$TAP_REPO/contents/$FORMULA_PATH" \
      --method PUT \
      --field message="chore: update rpi-image-resizer to v$VER" \
      --field content="$(echo "$FORMULA_CONTENT" | base64)" \
      --field sha="$CURRENT_SHA" \
      --field branch="main" > /dev/null
    echo "✓ Homebrew tap formula updated successfully!"
  else
    # Create new file
    echo "Creating formula in $TAP_REPO..."
    gh api "repos/$TAP_REPO/contents/$FORMULA_PATH" \
      --method PUT \
      --field message="chore: add rpi-image-resizer v$VER" \
      --field content="$(echo "$FORMULA_CONTENT" | base64)" \
      --field branch="main" > /dev/null
    echo "✓ Homebrew tap formula created successfully!"
  fi
else
  echo ""
  echo "⚠ GitHub CLI not found. Manual tap update required:"
  echo "   1. Copy rpi-image-resizer.rb to homebrew-rpi-tools repo"
  echo "   2. Commit: git commit -m \"chore: update rpi-image-resizer to v$VER\""
  echo "   3. Push: git push"
fi

echo ""
echo "Test installation:"
echo "   brew update"
echo "   brew reinstall aheissenberger/rpi-tools/rpi-image-resizer"
echo "   rpi-tool --version"