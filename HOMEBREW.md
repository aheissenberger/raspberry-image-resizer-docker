# Homebrew Distribution Guide

This document explains how to distribute the `rpi-tool` binary via Homebrew.

## Prerequisites

1. Build the binary for both architectures:
   ```bash
   bun run build  # Creates dist/rpi-tool
   ```

2. Create a GitHub release with binaries

## Creating a Release

### 1. Prepare Release Binaries

```bash
# Build for current architecture
bun run build

# Create release tarball (from project root)
cd dist
tar -czf rpi-tool-darwin-arm64.tar.gz rpi-tool  # For Apple Silicon
# OR
tar -czf rpi-tool-darwin-amd64.tar.gz rpi-tool  # For Intel
cd ..
```

### 2. Create GitHub Release

1. Go to: https://github.com/aheissenberger/raspberry-image-resizer-docker/releases
2. Click "Draft a new release"
3. Tag version: `v0.0.1` (match package.json version)
4. Release title: `v0.0.1 - Self-contained Binary with Auto-build`
5. Upload both tarballs:
   - `rpi-tool-darwin-arm64.tar.gz` (Apple Silicon)
   - `rpi-tool-darwin-amd64.tar.gz` (Intel)
6. Publish release

### 3. Generate SHA256 Checksums

```bash
# Download the release tarballs and generate checksums
shasum -a 256 rpi-tool-darwin-arm64.tar.gz
shasum -a 256 rpi-tool-darwin-amd64.tar.gz
```

### 4. Update Formula

Edit `rpi-image-resizer.rb`:

```ruby
# Update version
version "0.0.1"

# Update SHA256 checksums (from step 3)
if Hardware::CPU.arm?
  sha256 "abc123..."  # arm64 checksum
else
  sha256 "def456..."  # amd64 checksum
end
```

## Installation Methods (Homebrew 5+)

Homebrew requires formulae to live in a tap. Installing from a local file path is rejected.

### Method 1: Publish a Tap (recommended for users)

```bash
# Create a new tap repository managed by Homebrew (local git repo)
brew tap-new aheissenberger/rpi-tools

# Copy the formula into the tap
mkdir -p "$(brew --repo aheissenberger/rpi-tools)/Formula"
cp ./rpi-image-resizer.rb "$(brew --repo aheissenberger/rpi-tools)/Formula/"

# Commit it to the tap's git repo
git -C "$(brew --repo aheissenberger/rpi-tools)" add -A
git -C "$(brew --repo aheissenberger/rpi-tools)" commit -m "Add rpi-image-resizer formula"

# (Optional) Push to GitHub to share the tap
git -C "$(brew --repo aheissenberger/rpi-tools)" remote add origin https://github.com/aheissenberger/homebrew-rpi-tools.git
git -C "$(brew --repo aheissenberger/rpi-tools)" push -u origin HEAD

# Users can install with:
brew tap aheissenberger/rpi-tools
brew install rpi-image-resizer

# Verify
rpi-tool --version
```

### Method 2: Local Tap Only (development/testing)

If you don't want to publish yet, keep the tap local and install from it:

```bash
# Create the tap locally (if not already)
brew tap-new aheissenberger/rpi-tools

# Copy and commit the formula
mkdir -p "$(brew --repo aheissenberger/rpi-tools)/Formula"
cp ./rpi-image-resizer.rb "$(brew --repo aheissenberger/rpi-tools)/Formula/"
git -C "$(brew --repo aheissenberger/rpi-tools)" add -A
git -C "$(brew --repo aheissenberger/rpi-tools)" commit -m "Add rpi-image-resizer formula"

# Install from the local tap
brew install aheissenberger/rpi-tools/rpi-image-resizer

# Test and uninstall
rpi-tool --version
brew uninstall rpi-image-resizer
```

## Updating the Formula

When releasing a new version:

1. Update `package.json` version with `bun pm version patch`
2. Build and create release tarballs
3. Create GitHub release with new version tag
4. Generate new SHA256 checksums
5. Update formula:
   - `version` field
   - `url` fields (new version tag)
   - `sha256` fields (new checksums)
6. Push updated formula to tap repository

## Homebrew Formula Audit

Before submitting to Homebrew core (optional):

```bash
# Audit the formula in the tap for issues
brew audit --strict aheissenberger/rpi-tools/rpi-image-resizer

# Install from the tap, test, and uninstall
brew install aheissenberger/rpi-tools/rpi-image-resizer
brew test rpi-image-resizer
brew uninstall rpi-image-resizer
```

## Distributing to Homebrew Core (Optional)

For wider distribution, submit to Homebrew core:

1. Fork https://github.com/Homebrew/homebrew-core
2. Add formula to `Formula/r/rpi-image-resizer.rb`
3. Submit pull request
4. Address review feedback

Note: Homebrew core has strict requirements. A personal tap is easier to maintain.

## Architecture Support

The formula supports both Apple Silicon (arm64) and Intel (amd64) Macs using conditional URLs and checksums based on `Hardware::CPU.arm?`.

## Binary Size

The compiled binary is approximately 57MB and includes:
- Bun runtime
- Embedded Dockerfile
- Embedded worker.js
- All CLI code

## Dependencies

- **docker**: Required runtime dependency (Docker Desktop must be running)
- No build dependencies (pre-compiled binary)

## Caveats

The formula includes helpful installation notes about:
- Docker Desktop requirement
- Auto-build behavior on first run
- Basic usage examples
- Help command reference

These appear when users run `brew info rpi-image-resizer` or during installation.
