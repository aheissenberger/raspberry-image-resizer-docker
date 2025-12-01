#!/bin/bash
# Build script for creating Homebrew release artifacts

set -e

VERSION=$(node -p "require('./package.json').version")
BINARY_NAME="rpi-tool"

echo "Building release binaries for version ${VERSION}..."

# Ensure clean build
echo "Cleaning previous builds..."
bun run clean

# Build the CLI binary
echo "Building CLI binary..."
bun run build

# Check if binary exists
if [ ! -f "dist/${BINARY_NAME}" ]; then
    echo "Error: Binary not found at dist/${BINARY_NAME}"
    exit 1
fi

# Get architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    PLATFORM="darwin-arm64"
elif [ "$ARCH" = "x86_64" ]; then
    PLATFORM="darwin-amd64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Create release directory
RELEASE_DIR="release"
mkdir -p "${RELEASE_DIR}"

# Create tarball
TARBALL="${RELEASE_DIR}/${BINARY_NAME}-${PLATFORM}.tar.gz"
echo "Creating tarball: ${TARBALL}"
cd dist
tar -czf "../${TARBALL}" "${BINARY_NAME}"
cd ..

# Generate SHA256 checksum
CHECKSUM=$(shasum -a 256 "${TARBALL}" | awk '{print $1}')

echo ""
echo "✓ Release build complete!"
echo ""
echo "Binary: dist/${BINARY_NAME}"
echo "Archive: ${TARBALL}"
echo "SHA256: ${CHECKSUM}"
echo ""
echo "Next steps:"
echo "1. Create GitHub release tag v${VERSION}"
echo "2. Upload ${TARBALL} to the release"
echo "3. Update rpi-image-resizer.rb with:"
echo "   - version \"${VERSION}\""
echo "   - sha256 \"${CHECKSUM}\" (for ${PLATFORM})"
echo ""
echo "To generate checksum for other architecture:"
echo "  shasum -a 256 ${TARBALL}"
