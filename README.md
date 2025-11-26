# Raspberry Pi Image Resizer (Docker-Based)

A **cross-platform, safe, reproducible** solution for resizing and modifying Raspberry Pi `.img` files using Linux tools executed inside a Docker container.

## Features

- ✅ **SD Card Cloning**: Clone Raspberry Pi SD cards directly to image files
- ✅ **Safe**: Creates timestamped backups before any modification
- ✅ **Cross-platform**: Works on macOS (Intel & Apple Silicon) using Docker
- ✅ **Reproducible**: Uses pinned Docker images for consistent results
- ✅ **Boot partition resizing**: Adjust FAT32 boot partition size
- ✅ **File preservation**: Backs up and restores all boot files
- ✅ **Optional ext4 resize**: Opt-in support for root partition resizing
- ✅ **Dry-run mode**: Preview changes before applying them

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

### 2. Build the Docker Image

```bash
docker build -t rpi-image-resizer:latest .
```

This creates a Docker image with all necessary Linux tools (parted, e2fsck, mkfs.vfat, etc.).

### 3. Resize an Image

```bash
./resize-image.sh path/to/raspios.img
```

This will:
- Create a backup with timestamp: `raspios_202511261430.img`
- Resize the boot partition to 256MB (default)
- Preserve all boot files
- Leave the root partition intact

### 4. Clone an SD Card (Optional)

If you need to create an image from a physical SD card first:

```bash
./clone-sd.sh raspios-backup.img
```

This will:
- Scan for Raspberry Pi SD cards (identifies by `cmdline.txt`)
- Display a list of detected devices
- Let you select which SD card to clone
- Clone the entire SD card to an image file using `dd`

## Usage

### Cloning SD Cards

The `clone-sd.sh` script creates disk images from physical Raspberry Pi SD cards.

**Syntax:**
```bash
./clone-sd.sh <output-image-path>
```

**Example:**
```bash
./clone-sd.sh ~/Images/my-raspberrypi.img
```

**Process:**
1. Insert your Raspberry Pi SD card into your Mac
2. Run the clone script
3. Select the device from the numbered list
4. Confirm the operation
5. Wait for cloning to complete (can take 30 minutes to 2+ hours)

**Notes:**
- Requires sudo privileges for `dd` operation
- Uses raw device (`rdisk`) for faster performance
- Press `Ctrl+T` during cloning to see progress
- Automatically checks for sufficient disk space
- Only shows devices containing `cmdline.txt` (Raspberry Pi indicator)

---

### Resizing Images

### Basic Syntax

```bash
./resize-image.sh <path-to-image> [options]
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `--boot-size <MB>` | Size for boot partition in MB | 256 |
| `--unsafe-resize-ext4` | Enable ext4 root partition resizing | Disabled |
| `--dry-run` | Preview changes without modifying | Disabled |
| `--verbose` | Show detailed output from Docker | Disabled |
| `-h`, `--help` | Show help message | - |

### Examples

**Resize boot partition to 512MB:**
```bash
./resize-image.sh raspios.img --boot-size 512
```

**Preview changes without modifying:**
```bash
./resize-image.sh raspios.img --dry-run
```

**Resize both boot and root partitions (dangerous!):**
```bash
./resize-image.sh raspios.img --boot-size 512 --unsafe-resize-ext4
```

**Verbose output for debugging:**
```bash
./resize-image.sh raspios.img --boot-size 512 --verbose
```

## How It Works

1. **Backup Creation**: Creates timestamped backup (e.g., `image_202511261430.img`)
2. **Docker Launch**: Starts privileged Linux container with image mounted
3. **Loop Device**: Attaches image as `/dev/loop0` inside container
4. **Partition Analysis**: Examines partition table and filesystems
5. **Boot Backup**: Copies all files from boot partition (FAT32)
6. **Partition Resize**: Adjusts partition boundaries using `parted`
7. **Filesystem Creation**: Creates new FAT32 filesystem with `mkfs.vfat`
8. **File Restoration**: Restores backed-up boot files
9. **Cleanup**: Unmounts filesystems and detaches loop devices

## Safety Features

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
├── clone-sd.sh               # SD card cloning script (macOS)
├── resize-image.sh           # Image resizing launcher (macOS)
├── src/
│   └── resize-worker.sh      # Container worker script (Linux)
├── REQUIREMENTS.md           # Detailed requirements document
└── README.md                 # This file
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

---

### Image Resizing Issues

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
- Clones entire SD card (may result in large files)
- Cannot clone to raw devices, only to `.img` files

### Image Resizing
- Only works with `.img` files (not raw block devices)
- FAT32 resizing is destructive (requires backup/restore)
- Some unusual partition layouts (NOOBS, multi-boot) may not be supported
- Boot partition must be FAT32 (vfat)
- Root partition must be ext4 for resize operations

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
fdisk -l /dev/loop0
blkid /dev/loop0p1 /dev/loop0p2
```

### Running Without Docker

If you have a Linux system with the required tools, you can run the worker script directly:

```bash
sudo IMAGE_FILE=image.img BOOT_SIZE_MB=256 ./src/resize-worker.sh
```

### Complete Workflow Example

Clone an SD card and then resize it:

```bash
# Step 1: Clone your SD card to an image
./clone-sd.sh original-raspios.img

# Step 2: Resize the boot partition in the cloned image
./resize-image.sh original-raspios.img --boot-size 512

# The resized image will be saved as original-raspios_202511261430.img
# Original clone remains unchanged
```

## Contributing

Contributions welcome! Please:

1. Test changes on both Intel and Apple Silicon Macs if possible
2. Verify images boot successfully on actual Raspberry Pi hardware
3. Update documentation for new features
4. Follow existing code style and error handling patterns

## Future Enhancements

- [ ] GUI frontend (Electron or Swift)
- [ ] Support for GPT-based Raspberry Pi OS variants
- [ ] Verification mode: run `fsck` after each operation
- [ ] Image shrink functionality
- [ ] Support for other SBC image formats

## License

This project is provided as-is for educational and personal use.

## Acknowledgments

Built with Linux tools: `parted`, `losetup`, `e2fsck`, `resize2fs`, `mkfs.vfat`, and `rsync`.

---

**⚠️ Important**: Always test resized images on non-critical systems first. Keep backups of important data.
