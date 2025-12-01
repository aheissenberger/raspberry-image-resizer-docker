# Raspberry Pi Image Resizer (Docker-Based)

A **cross-platform, safe, reproducible** solution for resizing and modifying Raspberry Pi `.img` files using Linux tools executed inside a Docker container.

## Features

- ✅ **SD Card Cloning**: Clone Raspberry Pi SD cards directly to image files
- ✅ **SD Card Writing**: Write an image back to a Raspberry Pi SD card (with double confirmation)
- ✅ **Safe**: Creates timestamped backups before any modification
- ✅ **Cross-platform**: Works on macOS (Intel & Apple Silicon) using Docker
- ✅ **Reproducible**: Uses pinned Docker images for consistent results
- ✅ **Boot partition resizing**: Adjust FAT32 boot partition size
- ✅ **Automatic optimization**: Intelligently shrinks root partition when needed to avoid disk expansion
- ✅ **Overall image resizing**: `--image-size` grows or shrinks the entire image file (MB/GB/TB)
- ✅ **Partition moving**: Automatically moves partitions to make room for boot expansion
- ✅ **File preservation**: Backs up and restores all boot files
- ✅ **Optional ext4 resize**: Opt-in support for manual root partition resizing
- ✅ **Dry-run mode**: Preview changes before applying them
 - ✅ **Post-clone remount**: Automatically remounts mountable volumes of the SD card after cloning

## Requirements

- **macOS** 13 (Ventura), 14 (Sonoma), or 15 (Sequoia)
- **Docker Desktop** installed and running
- A Raspberry Pi disk image (`.img` file)
- Sufficient disk space for backup (same size as original image)

## Quick Start

### 1. Clone or Download This Repository

```bash
git clone <repository-url>
cd raspberry-image-resizer-docker
```

### 2. Install Dependencies

```bash
bun install
```

### 3. Build the CLI and Docker Image

```bash
# Build everything (CLI executable + Docker worker + Docker image)
bun run build
bun run docker:build

# The CLI is compiled to a standalone executable:
# ./dist/rpi-tool (no Bun runtime required on macOS)
```

This creates a Docker image with all necessary Linux tools (sfdisk, e2fsck, mkfs.vfat, kpartx, etc.).

### 4. Resize an Image

```bash
# Use the compiled executable (no Bun required)
./dist/rpi-tool resize path/to/raspios.img

# Or during development with Bun:
bun run src/cli.ts resize path/to/raspios.img
```

This will:
- Create a backup with timestamp: `raspios_202511261430.img`
- Resize the boot partition to 256MB (default)
- Preserve all boot files
- Leave the root partition intact

### 5. Clone or Write an SD Card (Optional)

If you need to create an image from a physical SD card first:

```bash
./dist/rpi-tool clone raspios-backup.img
```

This will:
- Scan for Raspberry Pi SD cards (identifies by `cmdline.txt`)
- Display a list of detected devices
- Let you select which SD card to clone
- Clone the entire SD card to an image file using `dd`
- Remount mountable volumes on the SD card after cloning completes

To write an image back to an SD card:

```bash
./dist/rpi-tool write raspios-backup.img
```

This will:
- Scan and list compatible SD card devices
- Prompt for device selection
- Ask for double confirmation ("yes" and final "WRITE")
- Unmount the selected device and write the image using `dd`

## Usage

### SD Card: Clone & Write (Bun CLI)

The combined Bun CLI handles cloning and writing, with optional compression support.

**Clone syntax:**
```bash
./dist/rpi-tool clone <output-image-path> [--compress <algorithm>] [--level <1-9|1-19>]
```

**Write syntax:**
```bash
./dist/rpi-tool write <image-path>
```

**Compression options:**
- `--compress <algorithm>`: Compress output using `zstd`, `xz`, or `gzip`
- `--level <1-9|1-19>`: Compression level (zstd: 1-19, xz/gzip: 1-9)

**Compression examples:**
```bash
# Clone with zstd compression (fast, good compression)
./dist/rpi-tool clone raspios-backup.img.zst --compress zstd --level 3

# Clone with xz compression (slow, best compression)
./dist/rpi-tool clone raspios-backup.img.xz --compress xz --level 9

# Clone with gzip compression (moderate speed and compression)
./dist/rpi-tool clone raspios-backup.img.gz --compress gzip --level 6

# Write a compressed image (auto-detects .zst/.xz/.gz)
./dist/rpi-tool write raspios-backup.img.zst
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
- **Compression**: Requires `zstd`, `xz`, or `gzip` installed (install via Homebrew: `brew install zstd xz`)
- **Write decompression**: Automatically detects `.zst`, `.xz`, `.gz` extensions and decompresses on-the-fly
- Requires sudo privileges for `dd` operation
- Uses raw device (`rdisk`) for faster performance
- Press `Ctrl+T` during operations to see progress
- Clone automatically checks for sufficient disk space
- Compressed images save significant disk space (often 50-70% reduction)
- On macOS, only mountable filesystems (e.g., FAT32 boot) will remount; ext4 root does not mount natively

---

### Resizing Images (Bun CLI)

### Basic Syntax

```bash
./dist/rpi-tool resize <path-to-image> [options]
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--boot-size <MB>` | Size for boot partition in MB | 256 |
| `--image-size <size>` | Resize whole image (supports `MB`, `GB`, `TB`) | - |
| `--unsafe-resize-ext4` | Enable ext4 root partition resizing | Disabled |
| `--dry-run` | Preview changes without modifying | Disabled |
| `--verbose` | Show detailed output from Docker | Disabled |
| `-h`, `--help` | Show help message | - |

### Examples

**Resize boot partition to 512MB:**
```bash
./dist/rpi-tool resize raspios.img --boot-size 512
```

**Resize a compressed image (auto-detects .zst/.xz/.gz):**
```bash
./dist/rpi-tool resize raspios.img.zst --boot-size 512
```

**Preview changes without modifying:**
```bash
./dist/rpi-tool resize raspios.img --dry-run
```

**Expand image and auto-grow root:**
```bash
./dist/rpi-tool resize raspios.img --image-size 64GB --boot-size 256
```

**Shrink image (only if safe):**
```bash
./dist/rpi-tool resize raspios.img --image-size 600MB --boot-size 64
```

**Verbose output for debugging:**
```bash
./dist/rpi-tool resize raspios.img --boot-size 512 --verbose
```

## How It Works

1. **Backup Creation**: Creates timestamped backup (e.g., `image_202511261430.img`)
2. **Docker Launch**: Starts privileged Linux container with image mounted
3. **Loop Device**: Attaches image as `/dev/loop0` inside container
4. **Partition Analysis**: Examines partition table and filesystems
5. **Usage Detection**: Checks actual filesystem usage to determine if shrinking is beneficial
6. **Automatic Shrinking**: Shrinks root filesystem and partition if needed (avoids disk expansion)
7. **Boot Backup**: Copies all files from boot partition (FAT32)
8. **Partition Moving**: Relocates root partition data with `dd` (backward copy when regions overlap)
9. **Partition Resize**: Adjusts boot partition boundaries using `sfdisk` scripts
10. **Filesystem Creation**: Creates new FAT32 filesystem with `mkfs.vfat`
11. **File Restoration**: Restores backed-up boot files
12. **Root Auto-Adjust** (when `--image-size` used): expands or shrinks root to fit the new image size
13. **Cleanup**: Unmounts filesystems and detaches loop devices

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
    ├── resize-image.sh
    │   ├── Creates backup
    │   ├── Validates inputs
    │   └── Launches Docker container
    │
    └── Docker Container (Ubuntu 24.04)
        └── resize-worker.sh
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
│   │   └── docker.ts          # Docker invocation wrapper
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
├── REQUIREMENTS.md            # Detailed requirements document
└── README.md                  # This file
```

## Troubleshooting

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
**Solution**: Check your internet connection and ensure Docker has sufficient resources (memory/disk space).

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
- Compressed images are automatically decompressed to a temporary file during processing
- Original compressed image is never modified (backup created from decompressed version)
- Temporary decompressed files are automatically cleaned up after processing
- FAT32 resizing is destructive (requires backup/restore)
- Some unusual partition layouts (NOOBS, multi-boot) may not be supported
- Boot partition must be FAT32 (vfat)
- Root partition must be ext4 for automatic shrinking and move operations
- Shrinking validates last partition end + 10MB safety margin; aborts if unsafe
- Partition moving operations are time-consuming for large filesystems:
  - 10GB partition: minutes to tens of minutes depending on I/O
  - Uses overlap-safe `dd` backward copy when ranges overlap

## Advanced Usage

### Building for Specific Architecture

The Dockerfile automatically supports both Intel (amd64) and Apple Silicon (arm64):

```bash
# Build for current architecture
docker build -t rpi-image-resizer:latest .

# Build multi-arch (requires buildx)
docker buildx build --platform linux/amd64,linux/arm64 -t rpi-image-resizer:latest .
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

### Complete Workflow Example

Clone an SD card and then resize it:

```bash
# Step 1: Clone your SD card to an image
./dist/rpi-tool clone original-raspios.img

# Step 2: Resize the boot partition in the cloned image
./dist/rpi-tool resize original-raspios.img --boot-size 512

# Optional: Expand or shrink the overall image and auto-adjust root
./dist/rpi-tool resize original-raspios.img --image-size 64GB --boot-size 256
./dist/rpi-tool resize original-raspios.img --image-size 600MB --boot-size 64

# The resized image will be saved as original-raspios_202511261430.img
# Original clone remains unchanged
```

## Migration from Bash Scripts

If you previously used `clone-sd.sh` and `resize-image.sh`, here's the mapping to the new compiled CLI:

| Old Command | New Command |
|-------------|-------------|
| `./clone-sd.sh clone output.img` | `./dist/rpi-tool clone output.img` |
| `./clone-sd.sh write input.img` | `./dist/rpi-tool write input.img` |
| `./resize-image.sh image.img --boot-size 512` | `./dist/rpi-tool resize image.img --boot-size 512` |

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
