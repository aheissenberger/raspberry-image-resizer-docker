# Raspberry Pi Image Resizer (Docker-Based)

A **cross-platform, safe, reproducible** solution for resizing and modifying Raspberry Pi `.img` files using Linux tools executed inside a Docker container.

## Features

- ✅ **SD Card Cloning**: Clone Raspberry Pi SD cards directly to image files
- ✅ **SD Card Writing**: Write an image back to a Raspberry Pi SD card (with double confirmation)
- ✅ **One-Step Deploy**: Resize image and write to SD card in a single command
- ✅ **Device size query**: Print removable device capacity with `size` command
- ✅ **Safe**: Creates timestamped backups before any modification
- ✅ **Cross-platform**: Works on macOS (Intel & Apple Silicon) using Docker
- ✅ **Reproducible**: Uses pinned Docker images for consistent results
- ✅ **Boot partition resizing**: Adjust FAT32 boot partition size
- ✅ **Automatic optimization**: Shrinks root when necessary and auto-grows root to occupy newly freed space
- ✅ **Overall image resizing**: `--image-size` grows or shrinks the image; root auto-expands/shrinks accordingly
- ✅ **Partition moving**: Rsync-based root relocation (overlap-safe) to make room for boot expansion
- ✅ **File preservation**: Backs up and restores all boot files
 - ✅ **Boot label preservation**: Retains existing FAT volume label when recreating boot filesystem (if present)
- ✅ **Optional ext4 resize**: Opt-in support for manual root partition resizing
- ✅ **Dry-run mode**: Preview changes before applying them
 - ✅ **Post-clone remount**: Automatically remounts mountable volumes of the SD card after cloning

## Requirements

- **macOS** 13 (Ventura), 14 (Sonoma), or 15 (Sequoia)
- **Docker Desktop** installed and running (Docker image auto-builds on first run)
- A Raspberry Pi disk image (`.img` file)
- Sufficient disk space for backup (same size as original image)

**Note:** The CLI binary embeds all necessary resources (Dockerfile and worker code). The Docker image will be automatically built on first use.

## Install (Homebrew)

```bash
# Add the tap (first time only)
brew tap aheissenberger/rpi-tools

# Install the precompiled binary
brew install rpi-image-resizer

# Verify installation
rpi-tool --version
```

Requirements: Docker Desktop must be installed and running. On first run, the Docker image builds automatically using embedded resources.

## Quick Start

### For End Users (Binary Distribution)

1. **Download the compiled binary**: `rpi-tool` (or build from source, see Development section)
2. **Ensure Docker Desktop is running**
3. **Run the tool**:

```bash
# First run automatically builds the Docker image (one-time, ~2 minutes)
./rpi-tool resize path/to/raspios.img

# Subsequent runs use the cached image (fast)
./rpi-tool resize another-image.img --boot-size 512

# Print version
./rpi-tool --version
# Or
./rpi-tool version
```

The binary is **self-contained** (57MB) and includes:
- Compiled CLI executable (no Bun runtime needed)
- Embedded Dockerfile
- Embedded worker code

On first run, it automatically builds a Docker image with all necessary Linux tools (sfdisk, e2fsck, mkfs.vfat, kpartx, etc.).

### For Developers (Build from Source)

```bash
# 1. Clone repository
git clone <repository-url>
cd raspberry-image-resizer-docker

# 2. Install dependencies
bun install

# 3. Build the CLI (embeds Dockerfile and worker)
bun run build

# 4. The CLI is now at ./dist/rpi-tool (self-contained, 57MB)
./dist/rpi-tool resize image.img
```

### Usage Examples

```bash
# Basic resize (auto-builds Docker image on first run)
./rpi-tool resize path/to/raspios.img

# With custom boot size
./rpi-tool resize path/to/raspios.img --boot-size 512

# One-step deploy: resize and write to SD card
./rpi-tool deploy raspios.img --verbose

# Clean up Docker images and build artifacts
./rpi-tool clean

# Developers: run from source with Bun
bun run src/cli.ts resize path/to/raspios.img

# Show version
./rpi-tool --version

# Show removable device size (auto-detect)
./rpi-tool size

# Show size for a specific device
./rpi-tool size --device /dev/disk4
```

This will:
- Create a backup with timestamp: `raspios_202511261430.img`
- Resize the boot partition to 256MB (default)
- Preserve all boot files
- Leave the root partition intact

### Clone, Write, or Deploy to SD Card

**Clone from SD card to image:**

```bash
./rpi-tool clone raspios-backup.img
```

This will:
- Scan for Raspberry Pi SD cards (identifies by `cmdline.txt`)
- Display a list of detected devices
- Let you select which SD card to clone
- Clone the entire SD card to an image file using `dd`
- Remount mountable volumes on the SD card after cloning completes

**Write image to SD card:**

```bash
./rpi-tool write raspios-backup.img
```

This will:
- Scan and list compatible SD card devices
- Prompt for device selection
- Ask for double confirmation ("yes" and final "WRITE")
- Unmount the selected device and write the image using `dd`

**Deploy: Resize and write in one step:**

```bash
./rpi-tool deploy raspios.img
```

This will:
- Auto-detect target SD card device
- Default image size to 98% of device capacity (safe fit)
- Resize image in Docker (same as `resize` command)
- Write resized image directly to SD card
- Delete working image after successful write (use `--keep-working` to preserve)

## Usage

### SD Card: Clone & Write (Bun CLI)

The combined Bun CLI handles cloning and writing, with optional compression support.

**Clone syntax:**
```bash
./rpi-tool clone <output-image-path> [--compress <algorithm>] [--level <1-9|1-19>]
```

**Write syntax:**
```bash
./rpi-tool write <image-path>
```

**Device size syntax:**
```bash
./rpi-tool size [--device </dev/diskN>]
```

**Compression options:**
- `--compress <algorithm>`: Compress output using `zstd`, `xz`, or `gzip`
- `--level <1-9|1-19>`: Compression level (zstd: 1-19, xz/gzip: 1-9)

**I/O options:**
- `--block-size <SIZE>`: `dd` block size (default `4m`). Accepts values like `512k`, `1m`, `2m`, `4m`, `8m`, `1g`. Larger blocks reduce syscall overhead; `4m` is a solid default for most macOS SD readers.
- `--device </dev/diskN>`: Override auto-detection and use a specific disk (advanced). Accepts `/dev/diskN` or `/dev/rdiskN` (raw). The tool will unmount/mount around the operation.
- `--yes` (write only): Skip interactive confirmations. Dangerous; use only in automated contexts when absolutely sure.
- `--preview`: Print the exact `dd` command that would run and exit without executing (safe, no changes).

**Compression examples:**
```bash
# Clone with zstd compression (fast, good compression)
./rpi-tool clone raspios-backup.img.zst --compress zstd --level 3

# Clone with xz compression (slow, best compression)
./rpi-tool clone raspios-backup.img.xz --compress xz --level 9

# Clone with gzip compression (moderate speed and compression)
./rpi-tool clone raspios-backup.img.gz --compress gzip --level 6

# Write a compressed image (auto-detects .zst/.xz/.gz)
./rpi-tool write raspios-backup.img.zst

# Tune block size (advanced)
./rpi-tool clone raspios-backup.img --block-size 8m
./rpi-tool write raspios-backup.img --block-size 2m

# Use a specific device (advanced)
./rpi-tool clone raspios-backup.img --device /dev/disk2
./rpi-tool write raspios-backup.img --device /dev/rdisk2

# Automation helpers
# Non-interactive write (DANGEROUS: ensure device is correct)
./rpi-tool write raspios-backup.img --device /dev/rdisk2 --yes

# Preview dd command only (no changes)
./rpi-tool clone raspios-backup.img --device /dev/rdisk2 --preview
./rpi-tool write raspios-backup.img --device /dev/rdisk2 --preview
```

**Clone process:**
1. Insert your Raspberry Pi SD card into your Mac
2. Run the clone script (with optional compression flags)
3. Select the device from the numbered list (filtered for Raspberry Pi indicators)
4. Confirm the operation
5. Wait for cloning to complete (can take 30 minutes to 2+ hours)
6. Volumes on the SD card are remounted where possible

**Write process:**
1. Ensure the target removable storage device is connected
2. Run the write command with a valid image path (compressed or uncompressed)
3. Select the target device from the list (shows all removable devices ≤ 2TB)
4. Confirm with "yes", then type "WRITE" to proceed (destructive)
5. The tool unmounts the target and writes the image with `dd`

**Notes:**
- **Clone**: Only lists devices with Raspberry Pi indicators (`cmdline.txt`, `config.txt`, etc.) for safety
- **Write**: Lists all removable devices ≤ 2TB (no Pi detection) - use with caution
- **Write preflight**: Aborts if an uncompressed image is larger than the selected device. For compressed streams (.zst/.xz/.gz), exact preflight of the uncompressed size is not available.
- **Compression**: Requires `zstd`, `xz`, or `gzip` installed (install via Homebrew: `brew install zstd xz`)
- **Write decompression**: Automatically detects `.zst`, `.xz`, `.gz` extensions and decompresses on-the-fly
- Requires sudo privileges for `dd` operation
- Uses raw device (`/dev/rdiskX`) for faster performance
- Continuous progress: `dd` runs with `status=progress`; the CLI streams progress from `stderr`
- Tip (macOS): Press `Ctrl+T` to trigger an immediate `dd` progress update
- Clone automatically checks for sufficient disk space
- Compressed images save significant disk space (often 50-70% reduction)
- On macOS, only mountable filesystems (e.g., FAT32 boot) will remount; ext4 root does not mount natively

### Performance Tips

- Raw device: Prefer `/dev/rdiskX` over `/dev/diskX` for significantly faster I/O on macOS.
- Block size: Use `--block-size` to tune `dd` throughput. `4m` is a strong default; many readers plateau around `4m–8m`. Larger values reduce syscalls but usually show diminishing returns beyond `8m`.
- Compression trade-offs: `zstd` is fastest with good ratios (multithreaded), `xz` compresses best but is slow (multithreaded), `gzip` is moderate and single-threaded. Pick based on whether CPU time or storage size is your priority.
- Progress: The CLI enables `dd status=progress` and streams updates continuously; you can press `Ctrl+T` on macOS for an immediate snapshot.

#### Quick benchmark (read-only)

Replace `rdisk2` with your source device to gauge throughput with common block sizes:

```zsh
for bs in 512k 1m 2m 4m 8m 16m; do
  echo "bs=$bs"
  sudo dd if=/dev/rdisk2 of=/dev/null bs=$bs count=2048 status=progress 2>&1 | tail -n1
done
```

This loop is read-only and safe: `if=/dev/rdisk2` reads from the card and `of=/dev/null` discards data (no writes to the device). `2>&1 | tail -n1` captures `dd`'s final summary line because progress is printed to `stderr`. If you want a quicker sample, lower `count` (e.g., `count=256`).

---

### Resizing Images

#### Basic Syntax

```bash
./rpi-tool resize <path-to-image> [options]
./rpi-tool deploy <path-to-image> [options]  # Resize + write to SD
```

#### Resize Options

| Option | Description | Default |
|--------|-------------|---------|
| `--boot-size <MB>` | Size for boot partition in MB | 256 |
| `--image-size <size>` | Resize whole image (supports `MB`, `GB`, `TB`) | - |
| `--unsafe-resize-ext4` | Enable ext4 root partition resizing | Disabled |
| `--dry-run` | Preview changes without modifying | Disabled |
| `--verbose` | Show detailed output from Docker and run a final read-only filesystem check (e2fsck -n) | Disabled |
| `--verify-fs` | Run a final read-only filesystem check (e2fsck -n) regardless of verbosity | Disabled |
| `--work-dir <path>` | Working directory for temp files and working image | For compressed inputs: `$TMPDIR` or `/tmp`; otherwise source dir |
| `-h`, `--help` | Show help message | - |

#### Deploy-Specific Options

| Option | Description | Default |
|--------|-------------|---------||
| `--device </dev/diskN>` | Override auto-detection and use a specific disk | Auto-detect |
| `--block-size <SIZE>` | dd block size (default 4m) | 4m |
| `--keep-working` | Keep working image after successful deploy | Delete after write |
| `--preview` | Print the dd command and exit (no write) | - |

> Note: Before setting a large `--image-size` (e.g., 64GB), first check your SD card's real capacity and pick a slightly smaller size to avoid short write errors.

```bash
# Auto-detect removable device size
./rpi-tool size

# Or specify a device explicitly
./rpi-tool size --device /dev/disk4

# Example: for a card reporting ~59.63 GiB, choose something like 62.9GB
./rpi-tool resize raspios.img --image-size 62.9GB
```

### Examples

**Resize boot partition to 512MB:**
```bash
./rpi-tool resize raspios.img --boot-size 512
```

**Resize a compressed image (auto-detects .zst/.xz/.gz):**
```bash
./rpi-tool resize raspios.img.zst --boot-size 512

# Use a custom working directory to avoid space issues in source dir
./rpi-tool resize raspios.img.zst --work-dir ~/Images/work --boot-size 512
```

**Preview changes without modifying:**
```bash
./rpi-tool resize raspios.img --dry-run
```

**Expand image and auto-grow root:**
```bash
./rpi-tool resize raspios.img --image-size 64GB --boot-size 256
```

> Tip: Before expanding to a nominal size (e.g., 64GB), check the card's real capacity with `./rpi-tool size` and choose a slightly smaller value to avoid short writes. For example, if the card reports around 59.63 GiB, use something like `--image-size 62.9GB`.

**Shrink image (only if safe):**
```bash
./rpi-tool resize raspios.img --image-size 600MB --boot-size 64
```

**Verbose output for debugging:**
```bash
./rpi-tool resize raspios.img --boot-size 512 --verbose
```

**Deploy examples:**
```bash
# Basic deploy (auto-size to device capacity)
./rpi-tool deploy raspios.img

# Deploy with explicit size and boot partition
./rpi-tool deploy raspios.img --image-size 32GB --boot-size 512

# Deploy compressed image with verbose output
./rpi-tool deploy raspios.img.zst --verbose

# Keep working image after deploy
./rpi-tool deploy raspios.img --keep-working

# Preview the dd command without writing
./rpi-tool deploy raspios.img --preview

# Deploy with specific device and block size
./rpi-tool deploy raspios.img --device /dev/disk4 --block-size 8m
```

## How It Works

### Resize Command

1. **Backup & Working Copy**:
   - If the input is compressed (`.img.zst/.xz/.gz`):
     - Creates a timestamped backup of the original compressed file in its source directory (e.g., `image_202511261430.zst`)
     - Decompresses directly into a working `.img` in the working directory (defaults to `$TMPDIR` or `/tmp`)
   - If the input is uncompressed (`.img`):
     - Copies the original `.img` into the working directory as a timestamped working `.img`
   - The original compressed file is never modified
2. **Docker Launch**: Starts privileged Linux container with image mounted
3. **Loop Device**: Attaches image as `/dev/loop0` inside container
4. **Partition Analysis**: Examines partition table and filesystems
6. **Usage Detection**: Checks filesystem usage to determine if shrinking is beneficial before moves
7. **Automatic Shrinking**: Shrinks root if required to fit layout without forced image growth
8. **Boot Backup**: Copies all files from boot partition (FAT32)
9. **Partition Moving**: Relocates root via rsync staging (overlap-safe, filesystem recreated then data restored)
10. **Partition Resize**: Adjusts boot partition boundaries using `sfdisk` scripts
11. **Filesystem Creation**: Creates new FAT32 filesystem with `mkfs.vfat`
12. **File Restoration**: Restores backed-up boot files
13. **Root Auto-Adjust**: Evaluates tail space after any layout/image change and grows/shrinks root to consume safe free space
14. **Cleanup**: Unmounts filesystems and detaches loop devices

> Boot volume label: If the original boot filesystem has a label (e.g. `BOOT`), it is detected before formatting and reapplied during FAT32 recreation. If no label exists, none is set (behavior unchanged).

### Deploy Command

1. **Device Detection**: Auto-detects removable SD card device (or use `--device`)
2. **Size Calculation**: If `--image-size` not provided, defaults to 98% of device capacity (safe fit)
3. **Resize Phase**: Executes full resize workflow (same as `resize` command)
4. **Preflight Check**: Validates final image size fits on target device
5. **Write Phase**: Unmounts device and writes resized image with `dd`
6. **Cleanup**: Deletes working image (unless `--keep-working` specified)
7. **Remount**: Remounts device volumes after write completes

## Safety Features

All disk manipulations are inside a docker container on the copy of the image and cannot access the disks on the host system.

### Automatic Backups
- Original image **never modified**
- All work performed on timestamped backup
- Backup preserved even if operation fails

### Error Handling
- Aborts if partitions overlap
- Validates filesystem types before proceeding
- Checks for corrupted images
- Clear error messages with actionable guidance

### Opt-in Dangerous Operations
- ext4 resizing disabled by default
- Requires explicit `--unsafe-resize-ext4` flag
- Warns user about potential data loss

## Architecture

```
macOS Host (Docker Desktop)
    │
    ├── rpi-tool (self-contained binary, 57MB)
    │   ├── Embedded Dockerfile
    │   ├── Embedded worker.js
    │   ├── Auto-builds Docker image on first run
    │   ├── Creates backup
    │   ├── Validates inputs
    │   └── Launches Docker container
    │
    └── Docker Container (Ubuntu 24.04 + Bun runtime)
        └── worker.js (TypeScript compiled)
            ├── Loop device management
            ├── Partition manipulation
            ├── Boot file backup/restore
            └── FAT32 filesystem creation
```

### File Structure

```
raspberry-image-resizer-docker/
├── Dockerfile                 # Docker image definition
├── package.json               # Bun project manifest & build scripts
├── bunfig.toml                # Bun configuration
├── tsconfig.json              # TypeScript configuration
├── src/
│   ├── cli.ts                 # Combined CLI (clone/write/resize)
│   ├── lib/                   # Shared libraries
│   │   ├── executor.ts        # Async process wrapper
│   │   ├── args.ts            # Argument parser
│   │   ├── compress.ts        # Compression utilities
│   │   ├── docker.ts          # Docker invocation wrapper
│   │   └── embedded.ts        # Embedded resources (Dockerfile, worker.js)
│   ├── worker/
│   │   └── worker.ts          # Container worker (TypeScript)
│   └── test-helper.ts         # E2E test harness (TypeScript)
├── tests/                     # Unit tests
│   ├── args.test.ts           # Argument parsing tests
│   ├── compress.test.ts       # Compression utilities tests
│   ├── docker.test.ts         # Docker wrapper tests
│   └── e2e/                   # End-to-end tests
│       ├── helpers.ts         # E2E test utilities
│       ├── resize.test.ts     # Core resize scenarios
│       └── compression.test.ts # Compression workflow tests
├── dist/                      # Build output (generated)
│   ├── rpi-tool               # Standalone CLI executable
│   └── worker/
│       └── worker.js          # Built worker for Docker
├── scripts/                   # Build and release automation
│   ├── build-release.sh       # Builds binary and creates release tarball
│   ├── update-formula.js      # Auto-updates version and SHA256 in formula
│   └── release.sh             # Complete release workflow (build → update → commit → publish)
├── rpi-image-resizer.rb       # Homebrew formula (tap distribution)
├── REQUIREMENTS.md            # Detailed requirements document
└── README.md                  # This file
```

## Release and Distribution

### Homebrew Formula Management

The project includes automated release tooling:

**Build and release:**
```bash
# Complete release workflow (automated)
bun run release
```

This script:
1. Builds the binary for current architecture (arm64 or amd64)
2. Creates tarball in `release/rpi-tool-darwin-<arch>.tar.gz`
3. Generates SHA256 checksum
4. Updates `rpi-image-resizer.rb` with version and checksum
5. Commits formula changes to repository
6. Creates or updates GitHub release with assets

**Manual steps (if needed):**
```bash
# Build binary and tarball
./scripts/build-release.sh

# Update formula with version and SHA256
node ./scripts/update-formula.js

# Publish formula to tap
cp rpi-image-resizer.rb "$(brew --repo aheissenberger/rpi-tools)/Formula/"
cd "$(brew --repo aheissenberger/rpi-tools)"
git add Formula/rpi-image-resizer.rb
git commit -m "chore: update rpi-image-resizer to v0.0.2"
git push
```

**Formula validation:**
```bash
# Audit formula for Homebrew standards compliance
brew audit rpi-image-resizer

# Test installation locally
brew reinstall rpi-image-resizer
```

### Multi-Architecture Support

The Homebrew formula supports both Apple Silicon and Intel Macs:
- **arm64**: Built on Apple Silicon Mac
- **amd64**: Built on Intel Mac or via cross-compilation

To build both architectures:
1. Build arm64 tarball on Apple Silicon Mac
2. Build amd64 tarball on Intel Mac (or use GitHub Actions)
3. Run `node ./scripts/update-formula.js` to update both SHA256 values
4. Run `bun run release` to publish release with both assets

## Troubleshooting

### Expand Root Partition After Boot (Raspberry Pi OS)

If you resized an image smaller than the SD card to ensure broad compatibility, you can expand the root filesystem on first boot to use the full card size.

Interactive (recommended on a connected Pi):

```bash
sudo raspi-config
# Navigate to: System Options → Resize FS (or Advanced Options → Expand Filesystem on older versions)
# Reboot when prompted
```

Non-interactive (headless):

```bash
# Newer Raspberry Pi OS:
sudo raspi-config --expand-rootfs
sudo reboot

# Fallback for older raspi-config versions:
sudo raspi-config nonint do_expand_rootfs
sudo reboot
```

Verify after reboot:

```bash
df -h /
lsblk
```

Alternative without raspi-config (works on Debian-based systems):

```bash
# Identify root partition
findmnt -no SOURCE /

# Example for the common layout (/dev/mmcblk0p2)
sudo apt-get update && sudo apt-get install -y cloud-guest-utils
sudo growpart /dev/mmcblk0 2
sudo resize2fs /dev/mmcblk0p2

# Verify
df -h /
```

### SD Card Cloning Issues

#### No Devices Detected
```
[ERROR] No Raspberry Pi SD cards detected.
```
**Solutions:**
- Ensure SD card is properly inserted and mounted
- Check that SD card contains Raspberry Pi OS (has `cmdline.txt` in boot partition)
- Try remounting: `diskutil list` to see if device appears
- Verify boot partition is mounted in Finder

#### Permission Denied During Clone
```
dd: /dev/rdisk2: Permission denied
```
**Solution:** The script requires sudo privileges. You'll be prompted for your password when `dd` runs.

#### Clone Taking Too Long
- This is normal for large SD cards (16GB+ can take 1-2 hours)
- Press `Ctrl+T` to see progress
- Using `rdisk` (raw device) is already the fastest method
- Consider cloning smaller partitions if you don't need the full card

#### Insufficient Disk Space
```
[ERROR] Insufficient disk space in /path/to/output
```
**Solution:** Free up space or choose a different output location with more available space.

#### Compression Tool Not Found
```
[ERROR] Compression tool 'zstd' is not installed
```
**Solution:** Install the required tool using Homebrew:
```bash
brew install zstd   # For zstd compression
brew install xz     # For xz compression
# gzip is pre-installed on macOS
```

---

### Image Resizing Issues

### Compressed Image Cannot Be Decompressed
```
[ERROR] Decompression tool 'zstd' is not installed
```
**Solution:** Install the required decompression tool using Homebrew:
```bash
brew install zstd   # For .zst files
brew install xz     # For .xz files
# gzip is pre-installed on macOS
```

### Docker Not Running
```
[ERROR] Docker is not running. Please start Docker Desktop.
```
**Solution**: Open Docker Desktop and wait for it to start completely.

### Image Not Found
```
[ERROR] Image file not found: path/to/image.img
```
**Solution**: Verify the path to your image file is correct and the file exists.

### Boot Partition Overlap Error
```
[ERROR] New boot partition size (512 MB) would overlap with root partition
```
**Solution**: Reduce the `--boot-size` value or use a smaller size that fits before the root partition.

### Permission Denied
```
[ERROR] Failed to create backup
```
**Solution**: Ensure you have write permissions in the directory containing the image.

### Docker Build Failed
```
[ERROR] Failed to build Docker image
```
**Solution**: Check your internet connection and ensure Docker has sufficient resources (memory/disk space). The image builds automatically on first run using embedded resources. To force a rebuild, remove the image: `docker rmi rpi-image-resizer:latest`

## Maintenance

### Cleaning Up

Remove Docker images and build artifacts to free disk space:

```bash
./rpi-tool clean
```

This command removes:
- Docker image: `rpi-image-resizer:latest`

The Docker image will be automatically rebuilt on the next resize operation.

## Limitations

### SD Card Cloning
- Only works on macOS (uses `diskutil` and `dd`)
- Requires physical SD card reader
- Clones entire SD card (may result in large files without compression)
- Cannot clone to raw devices, only to `.img` files (or compressed `.img.zst/.xz/.gz`)
- Compression requires `zstd`, `xz`, or `gzip` installed via Homebrew
- Multithreaded compression (zstd/xz) uses all available CPU cores for faster processing

### Image Resizing
- Only works with `.img` files or compressed `.img.zst/.xz/.gz` files (not raw block devices)
- Compressed images are automatically decompressed directly into a working `.img` in the working directory (default: `$TMPDIR` or `/tmp`)
- Original compressed image is never modified; a timestamped backup of the compressed file is created in the source directory
- The working `.img` remains in the working directory after processing (no extra copy back to source)
- FAT32 resizing is destructive (requires backup/restore)
- Some unusual partition layouts (NOOBS, multi-boot) may not be supported
- Boot partition must be FAT32 (vfat)
- Root partition must be ext4 for automatic shrinking and move operations
- Shrinking validates last partition end + 10MB safety margin; aborts if unsafe
- Partition moving operations use rsync for reliable data transfer:
  - Handles overlapping partitions safely via temporary storage
  - Performance depends on partition size and I/O speed
  - 10GB partition: typically several minutes

## Advanced Usage

### Embedded Resources and Auto-Build

The CLI binary embeds the Dockerfile and worker code at build time using Bun's import assertions:

```typescript
// Embedded at compile time
import WORKER_JS from "../../dist/worker/worker.js" with { type: "text" };
export const DOCKERFILE = `FROM ubuntu:24.04 ...`;
```

On first run, the CLI:
1. Checks if Docker image exists (`docker inspect`)
2. If missing, creates temp directory with embedded files
3. Runs `docker build` automatically
4. Cleans up temp directory
5. Subsequent runs use cached image

**Manual Docker build (development):**
```bash
# Build Docker image from source (not needed for binary)
bun run docker:build

# Or manually
docker build -t rpi-image-resizer:latest .
```

**Force rebuild:**
```bash
# Remove cached image to trigger auto-rebuild
docker rmi rpi-image-resizer:latest
./rpi-tool resize image.img  # Rebuilds automatically
```

### Inspecting Docker Container

To debug issues, you can run the container interactively:

```bash
docker run -it --rm --privileged -v "$PWD:/work" rpi-image-resizer:latest bash
```

Then manually run commands to investigate the image:

```bash
losetup -Pf /work/image.img
sfdisk -d /dev/loop0
blkid /dev/loop0p1 /dev/loop0p2
```

### Running Without Docker (advanced)

If you have a Linux system with all required tools, you can run the TS worker inside the container or directly via Bun (root required for loop/kpartx):

```bash
sudo IMAGE_FILE=image.img BOOT_SIZE_MB=256 VERBOSE=1 bun run src/worker/worker.ts
```

### Complete Workflow Examples

**Traditional workflow (clone → resize → write):**

```bash
# Step 1: Clone your SD card to an image
./rpi-tool clone original-raspios.img

# Step 2: Resize the boot partition in the cloned image
# (First run auto-builds Docker image)
./rpi-tool resize original-raspios.img --boot-size 512

# Step 3: Write resized image back to SD card
./rpi-tool write original-raspios_202511261430.img

# Optional: Expand or shrink the overall image and auto-adjust root
./rpi-tool resize original-raspios.img --image-size 64GB --boot-size 256
./rpi-tool resize original-raspios.img --image-size 600MB --boot-size 64
```

**Fast workflow (resize + write in one step):**

```bash
# One command: resize image and write to SD card
# Automatically sizes to fit target device
./rpi-tool deploy raspios.img --boot-size 512 --verbose

# Deploy with explicit size (useful for smaller target cards)
./rpi-tool deploy raspios.img --image-size 32GB --boot-size 256

# Deploy compressed image directly
./rpi-tool deploy raspios.img.zst --verbose
```

## Migration from Bash Scripts

If you previously used `clone-sd.sh` and `resize-image.sh`, here's the mapping to the new compiled CLI:

| Old Command | New Command |
|-------------|-------------|
| `./clone-sd.sh clone output.img` | `./rpi-tool clone output.img` |
| `./clone-sd.sh write input.img` | `./rpi-tool write input.img` |
| `./resize-image.sh image.img --boot-size 512` | `./rpi-tool resize image.img --boot-size 512` |

All features remain the same:
- Compression support (`--compress`, `--level`)
- Automatic decompression for `.zst/.xz/.gz` files
- Image size adjustment (`--image-size`)
- Dry-run and verbose modes
- Timestamped backups

## Contributing

Contributions welcome! Please:

1. Test changes on both Intel and Apple Silicon Macs if possible
2. Verify images boot successfully on actual Raspberry Pi hardware
3. Update documentation for new features
4. Follow existing TypeScript code style and error handling patterns
5. Add unit tests using Bun's native test framework
6. Ensure `bun test` passes before submitting
7. Run `brew audit rpi-image-resizer` to validate formula compliance before release
8. Update version in `package.json` using `bun version` before running release script

## Future Enhancements

- [ ] GUI frontend (Electron or Swift)
- [ ] Support for GPT-based Raspberry Pi OS variants
- [ ] Verification mode: run `fsck` after each operation
- [ ] Smart minimal image shrink (auto-compute min safe size)
- [ ] Support for other SBC image formats

## License

This project is provided as-is for educational and personal use.

## Acknowledgments

Built with Linux tools: `sfdisk`, `losetup`, `kpartx`, `e2fsck`, `resize2fs`, `mkfs.vfat`, `partprobe`, `blockdev`, and `rsync`.

---

**⚠️ Important**: Always test resized images on non-critical systems first. Keep backups of important data.

## Test Suite

### Unit Tests

Run unit tests for core utilities:

```bash
bun run test:unit
```

Tests cover:
- Argument parsing
- Compression detection and command building
- Docker wrapper utilities

### End-to-End Tests

Run comprehensive E2E tests (requires Docker):

```bash
# Build CLI and Docker image first
bun run build
bun run docker:build

# Run E2E tests
bun run test:e2e
```

**Core Functionality Tests** validate resize scenarios inside Docker:
- Test 1: No image change; boot 64MB→256MB; root shrinks and moves (files preserved)
- Test 2: Image expands 700MB→1500MB; boot 64MB→256MB; root auto-expands (files preserved)
- Test 3: Image shrinks 700MB→600MB; boot stays 64MB; shrink validated and applied (files preserved)

**Compression Workflow Tests** validate compression support across all algorithms:
- **Tool Validation**: Verifies zstd, xz, and gzip are available
- **Level Validation**: Tests compression level bounds (zstd: 1-19, xz/gzip: 1-9)
- **Detection Tests**: Validates automatic detection of .zst/.xz/.gz extensions
- **Compression Creation**: Tests creating compressed images with all three algorithms
- **Resize Compressed**: Tests resizing .zst, .xz, and .gz images with automatic decompression

All tests validate:
- Compressed images are created successfully with significant size reduction
- Original compressed files remain unchanged during resize operations
- Temporary decompressed files are automatically cleaned up
- Resized images have valid partition tables and filesystems
- File contents are preserved across all resize operations

### Run All Tests

```bash
bun run test:all
```
