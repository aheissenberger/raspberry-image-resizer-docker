# Raspberry Pi Image Resizer (Docker-Based) — Requirements Document

**Version:** 1.2  
**Date:** 2025-12-01  
**Author:** ChatGPT  

This document defines the functional and non-functional requirements for a Docker‑based implementation of a Raspberry Pi disk‑image manipulation and boot‑partition resizing tool.

---
## 1. Purpose

The goal of this project is to provide a **cross‑platform, safe, reproducible** solution for resizing and modifying Raspberry Pi `.img` files using **Linux tools executed inside a Docker container**, while the host system (macOS) simply supplies the image file.

Host orchestration is implemented in **Bun + TypeScript** for testability and maintainability.

This approach ensures:
- No need for a full Linux VM.
- **Advanced filesystem operations**: Direct access to ext4 tools allows safe resizing, checking, and repairing of Linux filesystems.
- **Native TypeScript implementation**: All orchestration and worker logic implemented in TypeScript for better maintainability and testability.

---

### **FR-3: Docker Runtime Requirements**
The Docker‑based solution shall:

- Accept a Raspberry Pi disk image (`.img`) from the macOS host.
- Examine and manipulate partitions using Linux tools.
- Resize or recreate the boot partition (FAT32).
- Leave the ext4 root filesystem intact unless explicitly requested.
- Run a **TypeScript worker** (`worker.js`) compiled from `src/worker/worker.ts` using Bun runtime inside the container.
- **Auto-build from embedded resources**: If Docker image doesn't exist:
  - Extract embedded Dockerfile and worker.js to temporary directory
  - Run `docker build` automatically
  - Clean up temporary files after build
  - Proceed with resize operation using newly built image
- Include `rsync` for reliable partition data moves

---

## 2. Definitions

| Term | Definition |
|------|------------|
| **Loop Device** | Virtual block device created via `losetup` for accessing partitions inside an image. |
| **Docker Host** | The macOS system running Docker Desktop. |
| **Worker Container** | The Linux environment performing the resizing operations. |
| **Bun** | Fast JavaScript/TypeScript runtime used for CLI and worker execution. |

---

## 3. Technical Architecture

- **CLI**: TypeScript-based command-line interface compiled to native executable (`dist/rpi-tool`, 57MB)
  - **Self-contained binary**: Embeds Dockerfile and worker.js at compile time
  - **Auto-build capability**: Automatically builds Docker image on first run if not present
  - **No manual Docker build required**: Users only need Docker Desktop running
- **Worker**: TypeScript resize logic (`src/worker/worker.ts`) compiled to JavaScript and executed in Docker
- **Embedded Resources** (`src/lib/embedded.ts`): Contains Dockerfile and worker.js as compile-time constants
- **Test Infrastructure**: TypeScript test harness (`src/test-helper.ts`) for E2E testing
- **Docker Container**: Ubuntu 24.04 with Bun runtime and Linux partition tools

---

## 4. Functional Requirements

### **FR-1: Input Parameters (Bun CLI)**
The system must accept:

```bash
bun run src/cli.ts resize <path-to-image> [--boot-size <MB>] [--image-size <size>] [--unsafe-resize-ext4] [--dry-run] [--verbose]
```

- `<path-to-image>` — required; must be a `.img` or raw image.
- `--boot-size <MB>` — optional; default: **256 MB**.
- `--image-size <size>` — optional; resize overall image file and automatically adjust root partition.
  - Accepts units: `MB`, `GB`, `TB` (e.g., `32GB`, `64GB`, `128GB`)
  - **Expanding**: Always allowed; appends zeros to grow the image file
  - **Shrinking**: Only allowed if there is sufficient free space after the last partition
  - Must be processed **before** any partition manipulation operations
  - **Triggers automatic root partition adjustment**: After boot resize completes, root partition automatically expands or shrinks to use all remaining space
  - Example use cases:
    - Resize a 32GB SD card image to 64GB, then expand root to fill the extra space
    - Shrink a 64GB image to 32GB, automatically shrinking root partition to fit
- `--unsafe-resize-ext4` — optional; allows modifying ext4 root partition (disabled by default).

---

### **FR-1b: Image Size Adjustment (Pre-Processing)**
If `--image-size` is specified, the system must resize the image file **before** any other operations:

**Expanding the image:**
1. Parse the target size and convert to bytes (supporting MB, GB, TB units)
2. Get current image file size
3. If target size > current size:
   - Expand image file using `truncate` or `dd`:
     ```bash
     truncate -s <target-size> image.img
     # OR
     dd if=/dev/zero bs=1M count=<additional-MB> >> image.img
     ```
4. Verify new file size matches target
5. Proceed with partition operations on expanded image

**Shrinking the image:**
1. Parse target size and convert to bytes
2. Attach image as loop device and analyze partition table
3. Calculate the end sector of the last partition (plus safety margin of 10MB)
4. Calculate minimum required image size in bytes
5. If target size < minimum required:
   - **Abort** with clear error message showing:
     - Current image size
     - Minimum required size (based on partitions)
     - Requested target size
     - Amount of additional space needed
6. If target size ≥ minimum required:
   - Detach loop device
   - Truncate image file to target size:
     ```bash
     truncate -s <target-size> image.img
     ```
7. Verify new file size
8. Proceed with partition operations on shrunk image

**Safety requirements:**
- Image size adjustment must occur **before backup creation** to avoid creating oversized backups
- Must validate target size is reasonable (e.g., not less than 100MB, not more than 10TB)
- Must check available disk space on host before expanding
- Shrinking validation must account for:
  - Root filesystem usage (prevent data loss)
  - All partition end boundaries
  - Safety margin (minimum 10MB after last partition)
  - Potential partition alignment requirements
- Provide clear progress indication for large resize operations
- On shrink failure, image file must remain at original size

**Automatic root partition adjustment workflow (implemented and tested):**
When `--image-size` is specified, the operation sequence is:
1. Resize image file (expand or shrink)
2. Create backup
3. Attach loop device
4. Resize boot partition to requested size
5. **Automatically adjust root partition** to use remaining space:
   - If image was expanded: grow root partition and filesystem to fill available space
   - If image was shrunk: verify root filesystem fits, then shrink root partition to available space
6. Verify all operations and detach loop device

Test coverage:
- No image change; boot grows to 256MB → root is automatically shrunk and moved if needed (files preserved)
- Image expands (700MB→1500MB); boot grows to 256MB → root is automatically expanded to consume remaining space (files preserved)
- Image shrinks (700MB→600MB) while boot remains 64MB → image shrink validated and applied; root remains within bounds; files preserved

---

### **FR-2: Backup Handling**
Before any modification (after optional image size adjustment):

- A timestamped backup must be created in the same directory.
- Format: `<name>_<YYYYMMDDHHMM>.img`
- All processing uses the backup.
- Original image must remain unmodified.
Before any modification:

- A timestamped backup must be created in the same directory.
- Format: `<name>_<YYYYMMDDHHMM>.img`
- All processing uses the backup.
- Original image must remain unmodified.

---

### **FR-3: Docker Runtime Requirements**
The tool must:

- Start a Linux container with proper privileges:

```
docker run --rm -it --privileged -v "$PWD":/work <image>
```

- Use a Docker image that includes:
  - `sfdisk` (partition table dump/apply)
  - `losetup`
  - `kpartx`
  - `e2fsprogs` (`e2fsck`, `resize2fs`)
  - `dosfstools` (`mkfs.vfat`)
  - `mount/umount`, `blkid`, `lsblk`
  - `partprobe`, `blockdev`, `rsync`

- Support both Intel and Apple Silicon via multi-arch images.

---

### **FR-4: Loop Device Management**
Inside the Docker container, the system must:

1. Associate the image with a loop device:
   ```
   losetup -Pf /work/image.img
   ```
2. Detect created partitions via:
  ```
  sfdisk -d /dev/loop0
  lsblk /dev/loop0
  blkid
  ```
3. Provide clear error messages if:
   - partitions cannot be detected,
   - the image is corrupted,
   - loop device cannot be allocated.

---

### **FR-5: Boot Partition Backup**
The container must:

- Mount `/dev/loop0p1` to `/mnt/boot`
- Copy all boot files to `/boot-backup`
- Unmount before modifying partitions

---

### **FR-6: Partition Table Modification**
The tool must support:

- **Expanding boot partition size** (if free space exists after root partition)
- **Automatic root partition shrinking** when needed:
  - Detects when boot expansion requires moving root partition
  - Checks actual filesystem usage of root partition
  - Calculates minimum safe size (used space × 1.2 + 100MB buffer)
  - Automatically shrinks root partition before moving if needed
  - Eliminates the need to manually expand disk images in most cases
- **Moving and resizing partitions** using full Linux container capabilities:
  - Can move the root partition to make room for boot partition expansion
  - Uses rsync for reliable data relocation (handles overlap via temporary storage)
  - Rewrites the partition table using `sfdisk` scripts (dump/apply) for deterministic changes
  - Uses `kpartx` for partition device mapping when needed
- **Recreating FAT32 partition** when required
- **Adjusting partition boundaries** using `sfdisk`:

```
# Example script applied via sfdisk
label: dos
unit: sectors

/dev/loop0p1 : start=<start>, size=<size>, type=c, bootable
/dev/loop0p2 : start=<start>, size=<size>, type=83
```

The Linux container environment enables:
- Deterministic partition table manipulation (MBR/DOS) via `sfdisk`
- Safe data relocation using rsync with temporary storage for overlap safety
- Resizing ext4 filesystems offline
- Complex multi‑partition operations
- Intelligent space optimization based on actual usage

Space management:
- If boot expansion requires moving root, the tool automatically checks if shrinking is beneficial
- Only requires disk expansion if root filesystem is genuinely too full to shrink
- Do NOT modify the root partition unless `--unsafe-resize-ext4` is provided or automatic shrinking is needed

---

### **FR-7: FAT32 Recreation and File Restore**
After modifying partition 1:

1. Run:
   ```
   mkfs.vfat -F 32 /dev/loop0p1
   ```
2. Mount `/dev/loop0p1`
3. Restore backed‑up boot files
4. Unmount

---

### **FR-8: Root Partition Resize**

**Automatic Root Partition Adjustment with `--image-size`:**
When `--image-size` is specified, after boot partition resize completes:

1. **Calculate available space**:
   - Determine end of boot partition (after resize to requested size)
   - Calculate remaining space: (total disk sectors) - (boot end sector) - (alignment buffer)
   
2. **Expand root partition** if image was grown:
   - Update partition table to use all available space after boot partition
   - Expand ext4 filesystem to fill the enlarged partition:
     ```bash
     e2fsck -f /dev/loop0p2
     resize2fs /dev/loop0p2
     ```
   - Automatically enabled when `--image-size` results in more space than current root partition
   
3. **Shrink root partition** if image was shrunk:
   - Check current filesystem usage
   - Verify target size accommodates: (used space × 1.2) + 100MB buffer
   - Shrink filesystem first, then update partition table:
     ```bash
     e2fsck -f /dev/loop0p2
     resize2fs /dev/loop0p2 <new-size>M
     sfdisk --force --no-reread /dev/loop0 < new-layout.sfdisk
     ```
   - Only allowed if sufficient free space exists in filesystem

**Automatic Shrinking (enabled by default when needed):**
When boot partition expansion requires moving the root partition:

- **Check filesystem usage** by mounting and running `df`
- **Calculate minimum safe size**: (used space × 1.2) + 100MB buffer
- **Automatically shrink** if moving would exceed disk capacity:
  ```
  e2fsck -f /dev/loop0p2
  resize2fs /dev/loop0p2 <calculated-size>M
  # Update partition table via sfdisk script
  sfdisk --force --no-reread /dev/loop0 < new-layout.sfdisk
  ```
- **Move partition** to new location after shrinking using overlap‑safe `dd`
- **Expand filesystem** to fill new partition size if it grew

**Manual Operations (only when `--unsafe-resize-ext4` is explicitly enabled):**

- **Shrink ext4 filesystem** before reducing partition size:
  ```
  e2fsck -f /dev/loop0p2
  resize2fs /dev/loop0p2 <new-size>
  ```
- **Expand ext4 filesystem** after increasing partition size:
  ```
  resize2fs /dev/loop0p2
  ```
- **Adjust partition boundaries** via `sfdisk` scripts

The Linux container provides full capabilities for:
- Offline ext4 filesystem operations (shrink, expand, check)
- Moving ext4 partitions to different disk locations
- Modifying partition table without data loss (when sufficient space exists)
- Running comprehensive filesystem integrity checks before and after operations
- Intelligent automatic optimization based on actual filesystem usage
- Automatic root partition expansion/shrinking when image size is adjusted

---

### **FR-9: Cleanup and Detach**
The system must:

- Unmount all mounts
- Detach loop devices:
  ```
  losetup -d /dev/loop0
  ```
- End and remove the Docker container

---

### **FR-10: SD Card Clone and Write**
The system must provide commands to clone a Raspberry Pi SD card to an image file, and write an image file back to an SD card:

```bash
bun run src/cli.ts clone <output-image-path> [--compress <algorithm>] [--level <1-9|1-19>]
bun run src/cli.ts write <image-path>
```

**Compression Support:**
The clone command supports optional on-the-fly compression with the following algorithms:
- **zstd**: Fast compression with good ratios (levels 1-19, default 3, uses all CPU cores)
- **xz**: Slower compression with best ratios (levels 1-9, default 6, uses all CPU cores)
- **gzip**: Moderate speed and compression (levels 1-9, default 6, single-threaded)

Compression requirements:
- Tool availability must be validated before cloning begins
- Output filename extension should match algorithm (`.zst`, `.xz`, `.gz`)
- Compression level must be within valid range for the algorithm
- Progress indication should account for compression overhead
- Host system must have compression tool installed (via Homebrew on macOS)

**Decompression Support:**
The write and resize commands automatically detect and decompress compressed images:
- Detects compression by file extension: `.zst`, `.xz`, `.gz`
- Decompresses to temporary file during resize operations
- Decompresses on-the-fly during write operation (streaming, no temp file)
- Validates decompression tool availability before operations begin
- Progress indication reflects decompression overhead
- Temporary files are automatically cleaned up after resize completes

The clone command must:

1. Scan all removable media devices (including internal SD card readers)
2. Check each device for Raspberry Pi indicators using a multi-factor detection approach:
   - **Primary indicators** (any 2 required):
     - `cmdline.txt` - Kernel command line parameters
     - `config.txt` - Raspberry Pi firmware configuration
     - `start.elf` or `start4.elf` - GPU firmware binary
     - `overlays/` directory - Device tree overlays
   - **Secondary indicators** (optional confirmations):
     - `bootcode.bin` - First stage bootloader
     - `kernel*.img` - Linux kernel files
     - `bcm27*.dtb` - Device tree blobs
3. Display a numbered list of detected Raspberry Pi SD cards showing:
   - Index number
   - Device path (e.g., `/dev/disk2`)
   - Device name/label
   - Total size
   - Detection confidence (number of indicators found)
4. Prompt user to enter the index number to select the device
5. Confirm the selection before proceeding
6. Use `dd` to clone the entire device to the specified output image file
7. Display progress during cloning operation
8. Verify the output image was created successfully
9. Remount all mountable volumes of the source device upon completion

**Clone progress and performance (implementation requirements):**

- Use `dd` with continuous progress: `status=progress` must be enabled so users see byte counters while cloning. Progress is emitted on `stderr` and forwarded by the CLI in real time.
- Prefer raw device nodes for speed on macOS: use `/dev/rdiskX` instead of `/dev/diskX` when invoking `dd`.
- Recommended defaults: `bs=4m conv=sync,noerror` to handle read hiccups without aborting and to write efficiently in large chunks.
- Example (uncompressed clone):
  ```bash
  dd if=/dev/rdisk2 of=./raspi.img bs=4m conv=sync,noerror status=progress
  ```
- Example (compressed clone with zstd, default level 3, all cores):
  ```bash
  dd if=/dev/rdisk2 bs=4m conv=sync,noerror status=progress | zstd -T0 -3 -o ./raspi.img.zst
  ```
- Example (compressed clone with xz, default level 6, all cores):
  ```bash
  dd if=/dev/rdisk2 bs=4m conv=sync,noerror status=progress | xz -T0 -6 > ./raspi.img.xz
  ```
- Example (compressed clone with gzip, default level 6, single-threaded):
  ```bash
  dd if=/dev/rdisk2 bs=4m conv=sync,noerror status=progress | gzip -6 > ./raspi.img.gz
  ```
- Tool validation: before cloning begins, the CLI must verify required compressors exist based on `--compress` selection and provide Homebrew install hints if missing.
- Filename extension policy: enforce `.zst`, `.xz`, `.gz` to match the chosen algorithm; error if inconsistent.
- Compression levels: validate allowable ranges (`zstd` 1–19, `xz` 1–9, `gzip` 1–9) and default accordingly when omitted.

The write command must:

1. Accept a path to an existing image file
2. Scan for **removable devices ≤ 2TB only** (no Raspberry Pi detection required)
   - Must be removable media
   - Must be ≤ 2TB in size
3. Display a numbered list of all compatible devices (no Pi-specific filtering)
4. Allow interactive selection of the target device
5. Require double confirmation before writing ("yes" and final "WRITE")

**Write streaming and progress (implementation requirements):**

- For compressed images, perform on-the-fly decompression piped directly into `dd` (no temporary file):
  - zstd: `zstd -dc ./raspi.img.zst | dd of=/dev/rdiskX bs=4m status=progress`
  - xz: `xz -dc ./raspi.img.xz | dd of=/dev/rdiskX bs=4m status=progress`
  - gzip: `gzip -dc ./raspi.img.gz | dd of=/dev/rdiskX bs=4m status=progress`
- For uncompressed images, write with: `dd if=./raspi.img of=/dev/rdiskX bs=4m status=progress`.
- Progress visibility: ensure `dd` progress (on `stderr`) is streamed to the user continuously by the CLI.
- Safety: retain the existing double-confirmation flow and re-scan/remount behavior after completion.
## 6. Risks & Limitations

- Docker on macOS cannot access raw block devices (e.g., `/dev/disk2`) — only `.img` files.
  - **Workaround**: Use `clone-sd.sh` to first clone SD card to `.img` file, then manipulate the image.
- FAT resizing is destructive; partition files must be backed up and restored.
- Some images may have unusual partition layouts (NOOBS, multi-boot).
- **Compression and decompression**:
  - Requires compression tools (`zstd`, `xz`, `gzip`) installed on host system
  - Compression significantly increases cloning time (2-5x longer depending on algorithm and level)
  - Decompression during resize creates temporary files (requires 2x space: compressed + decompressed)
  - Temporary decompressed files are automatically cleaned up, but large images may temporarily consume significant disk space
  - Compressed images cannot be directly manipulated; must be decompressed first
  - File extension must match compression algorithm for auto-detection (`.zst`, `.xz`, `.gz`)
- **Image size adjustment**:
  - Expanding image files is fast but requires sufficient host disk space (can be several GB).
  - Shrinking below minimum required size (end of last partition + 10MB) will fail with clear error.
  - Very large expansions (e.g., 32GB → 500GB) may take time depending on filesystem write speed.
  - Shrinking does not reclaim space from partition gaps or empty regions within partitions—only truncates after the last partition boundary.
  - Image size changes are persistent and affect the backup file size.
- **Partition movement operations**:
  - Moving partitions uses rsync for reliable data transfer via temporary storage.
  - **Automatic optimization**: The tool detects when shrinking root before moving eliminates the need for image expansion.
  - **`--image-size` integration**: Expanding image size before operations provides the space needed for partition moves.
  - Uses deterministic `sfdisk` table scripts to rewrite partition entries.
  - Rsync handles overlapping partitions safely by copying to temporary location first.
  - Moving ext4 partitions is safe and efficient (typically several minutes for 10GB+).
  - Most boot expansion operations complete without requiring manual disk image expansion.
- **Filesystem resizing constraints**:
✔ `--image-size` parameter correctly expands image files with MB/GB/TB units  
✔ Image expansion occurs before backup creation to avoid oversized backups  
✔ Shrinking validation prevents truncating active partition data  
✔ Clear error messages when shrinking below minimum required size  
✔ Expanded images provide sufficient space for subsequent partition operations  
✔ Root partition automatically expands to fill space when image is grown with `--image-size`  
✔ Root partition automatically shrinks safely when image is reduced with `--image-size`  
✔ Root filesystem expansion/shrinking occurs after boot partition resize completes
✔ Root partition remains intact unless explicitly modified  
✔ The output image boots successfully on a Raspberry Pi  
✔ Docker logs show all commands executed inside the container  
✔ Running `clone-sd.sh` detects Raspberry Pi SD cards and clones them to image files  
✔ SD card detection correctly identifies devices with `cmdline.txt`  
✔ User can select device by index number  
✔ Cloned image is bootable and identical to source SD card  
✔ Clone with `--compress zstd` produces compressed `.zst` file that is significantly smaller  
✔ Clone with `--compress xz --level 9` produces highly compressed `.xz` file  
✔ Write command auto-detects `.zst/.xz/.gz` extensions and decompresses on-the-fly  
✔ Compression tool validation fails gracefully with install instructions when tool missing  
✔ Compression level validation rejects invalid levels (e.g., zstd level 25, xz level 15)  
✔ `resize-image.sh` accepts compressed images (`.img.zst/.xz/.gz`) and decompresses to temp file  
✔ Temporary decompressed files are cleaned up automatically after resize operations  
✔ Decompression tool validation fails gracefully with Homebrew install instructions  
✔ **Compression test suite** (`test-compression.sh`) validates all workflows: 32/32 tests passing  
✔ Compression achieves significant size reduction on real disk images (typically 50-70%)  
✔ Resize operations on compressed images preserve file integrity and partition structure  
✔ Automatic cleanup prevents disk space leaks from temporary decompressed files  
✔ `--image-size` parameter correctly expands image files with MB/GB/TB units  
✔ Image expansion occurs before backup creation to avoid oversized backups  
✔ Shrinking validation prevents truncating active partition data  
✔ Clear error messages when shrinking below minimum required size  
✔ Expanded images provide sufficient space for subsequent partition operations

---

## 8. Test Coverage

### Unit Tests (`tests/*.test.ts`)
- **Argument Parsing** (`args.test.ts`): CLI argument validation and parsing logic
- **Compression Utilities** (`compress.test.ts`): Compression algorithm detection and validation
- **Docker Wrapper** (`docker.test.ts`): Docker invocation and parameter passing
- **Total**: 5 unit tests passing

### E2E Resize Tests (`tests/e2e/resize.test.ts`)
- **Test 1**: Boot partition expansion (64MB→256MB) with root shrink and move
  - Creates 700MB test image with files in boot and root partitions
  - Expands boot to 256MB, requires moving root partition
  - Uses rsync-based move strategy for reliable data transfer
  - Validates file integrity via SHA256 snapshots (pre/post)
  - Confirms partition layout and filesystem health
  - Typical completion time: ~8 seconds
- **Test 2**: Image expansion (700MB→1500MB) with boot expansion and root auto-grow
  - Expands image to 1500MB providing additional space
  - Expands boot to 256MB
  - Automatically expands root to consume all remaining space
  - Preserves all files during expansion
  - Typical completion time: ~8 seconds
- **Test 3**: Image shrinking (700MB→600MB) with validation
  - Shrinks image by 100MB while keeping boot at 64MB
  - Validates root partition fits within new image boundary
  - Confirms safe truncation without data loss
  - Tests shrink validation logic
  - Typical completion time: ~6 seconds
- **Infrastructure**: TypeScript test harness (`src/test-helper.ts`) creates test images, orchestrates Docker operations
- **Total**: 3 E2E resize tests passing (~22 seconds total)

### E2E Compression Tests (`tests/e2e/compression.test.ts`)
- **Dry-run Detection**: Tests compression format detection without decompression
  - Creates .zst, .xz, .gz dummy files
  - Validates CLI detects compression by file extension
  - Confirms dry-run skips decompression (detection messages on stderr)
- **Resize Compressed Image**: Tests full decompression and resize workflow
  - Creates real compressed test image (.zst)
  - Validates automatic decompression to temporary file
  - Performs resize operation on decompressed image
  - Confirms resized image has valid partition table
  - Verifies temporary file cleanup
- **Total**: 2 E2E compression tests passing

### Test Framework
- **Runtime**: Bun native test runner
- **Timeout**: 300 seconds for long-running Docker operations
- **Test Name Filtering**: `bun test --test-name-pattern <pattern>` for targeted test execution
- **Build Validation**: All tests run on compiled output (`dist/worker/worker.js`)
- **Coverage**: 100% of core workflows validated
- **Embedded Resources**: Tests validate auto-build from embedded Dockerfile and worker.js

**Overall Test Results**: 10/10 tests passing (5 unit + 2 compression + 3 resize E2E)

---

## 9. Implementation Status

### Completed
- ✅ **Full TypeScript Migration**: All bash scripts converted to native TypeScript
- ✅ **Native Bun APIs**: Using Bun.spawn, Bun.file, Bun.Glob, Bun.CryptoHasher throughout
- ✅ **Comprehensive Test Suite**: 10/10 tests passing (5 unit + 2 compression + 3 resize E2E)
- ✅ **Image Size Adjustment**: Expand/shrink images with automatic root partition adjustment
- ✅ **Compression Support**: Auto-detect and decompress .zst/.xz/.gz files
- ✅ **Dry-run Mode**: Preview operations without destructive actions
- ✅ **Loop Device Management**: Proper cleanup and detachment in all code paths
- ✅ **Rsync-based Partition Moves**: Simple, reliable, fast strategy for root partition relocation
  - Handles overlapping partitions safely via temporary storage
  - Typical performance: ~8 seconds per test for 700MB images
  - Replaces complex dd-based backward copy logic
- ✅ **Embedded Docker Image**: Self-contained binary with auto-build capability
  - Dockerfile and worker.js embedded at compile time using Bun import assertions
  - Automatic Docker image build on first run (no manual docker build needed)
  - Binary size: 57MB (includes Bun runtime + embedded resources)
  - Users only need Docker Desktop running
- ✅ **Production Ready**: Compiled worker (~22 KB), compiled CLI (57MB), zero bash dependencies, single-binary distribution
- ✅ **Release Automation**:
  - Automated build script (`scripts/build-release.sh`) for binary and tarball creation
  - Formula update script (`scripts/update-formula.js`) auto-injects version and SHA256
  - Complete release workflow script (`scripts/release.sh`) handles:
    - Build artifacts (binary + tarball)
    - Formula version/SHA256 updates
    - Git commit and push of formula changes
    - GitHub release creation or asset upload (via GitHub CLI)
  - Homebrew formula compliance: passes `brew audit` with zero warnings
  - Multi-architecture support: arm64 and amd64 tarballs with separate SHA256
  - Single command release: `bun run release`

### Future Enhancements

- GUI frontend (Electron or Swift)
- Support for GPT‑based Raspberry Pi OS variants
- Verification mode: run `fsck` after each operation
- Automatic image shrink: analyze partitions and shrink image to minimum size plus configurable margin
- **Release automation improvements**:
  - Cross-compilation support for amd64 from arm64 hosts (and vice versa)
  - GitHub Actions workflow for multi-arch releases
  - Automated formula publishing to Homebrew tap repository
  - Version bump automation integrated into release script
- **Advanced partition operations**:
  - Multi-partition layout support (more than 2 partitions)
  - GPT partition table support
  - Additional filesystem types (Btrfs, XFS, F2FS)
- Docker image versions must be pinned (e.g., Ubuntu 24.04).
- All commands executed inside container must be logged (verbose mode).

### **NFR-4: Usability**
Tool must:

- Display clear progress messages
- Fail with meaningful error messages
- Provide a `--dry-run` mode for previewing changes

### **NFR-5: Maintainability**
- Must be structured as:
  - `Dockerfile` (Ubuntu 24.04 + Bun runtime + Linux tools)
  - `src/cli.ts` (TypeScript CLI with resize/clone/write commands)
  - `src/worker/worker.ts` (TypeScript worker for container execution)
  - `src/test-helper.ts` (TypeScript E2E test harness)
  - `dist/rpi-tool` (compiled native executable)
  - `dist/worker/worker.js` (compiled worker for Docker)

---

## 6. Risks & Limitations

- Docker on macOS cannot access raw block devices (e.g., `/dev/disk2`) — only `.img` files.
  - **Workaround**: Use `clone-sd.sh` to first clone SD card to `.img` file, then manipulate the image.
- FAT resizing is destructive; partition files must be backed up and restored.
- Some images may have unusual partition layouts (NOOBS, multi-boot).
- **Partition movement operations**:
  - Moving partitions requires sufficient free space on the disk image.
  - **Automatic optimization**: The tool detects when shrinking root before moving eliminates the need for image expansion.
  - Uses deterministic `sfdisk` table scripts to rewrite partition entries.
  - Uses rsync with temporary staging for any needed root relocation (dd strategy deprecated).
  - Moving ext4 partitions is safe but time‑consuming for large filesystems (can take 10+ minutes for 10GB+).
  - Most boot expansion operations complete without requiring manual disk image expansion.
- **Filesystem resizing constraints**:
  - ext4 can only be shrunk to the size of its current data usage (plus 20% safety buffer and 500MB).
  - FAT32 partitions must be recreated to resize (data backup/restore required).
  - Filesystem check (`e2fsck`) is mandatory before shrinking ext4 partitions.
  - Automatic shrinking only occurs when necessary to fit partitions within existing disk space.

---

## 7. Acceptance Criteria

### CLI and Core Functionality
✔ Running `bun run src/cli.ts resize` creates a backup of the input image  
✔ Boot partition enlarges to the requested size  
✔ Boot files are preserved  
✔ Root partition remains intact unless explicitly modified  
✔ The output image boots successfully on a Raspberry Pi  
✔ Docker logs show all commands executed inside the container  
✔ Running `bun run src/cli.ts clone` detects Raspberry Pi SD cards and clones them to image files  
✔ SD card detection correctly identifies devices with `cmdline.txt`  
✔ User can select device by index number  
✔ Cloned image is bootable and identical to source SD card

### Image Size Adjustment
✔ `--image-size` parameter correctly expands image files with MB/GB/TB units  
✔ Image expansion occurs before backup creation to avoid oversized backups  
✔ Shrinking validation prevents truncating active partition data  
✔ Clear error messages when shrinking below minimum required size  
✔ Expanded images provide sufficient space for subsequent partition operations  
✔ Root partition automatically expands to fill space when image grows or when free tail space appears after boot/root moves  
✔ Root partition automatically shrinks safely when image is reduced with `--image-size`  
✔ Root filesystem expansion/shrinking occurs after boot partition resize or other layout changes

### TypeScript Implementation
✔ All bash commands eliminated from codebase (worker, test-helper, CLI)  
✔ Worker implemented in TypeScript with native Bun APIs (Bun.spawn, Bun.file, etc.)  
✔ Test harness implemented in TypeScript (`src/test-helper.ts`)  
✔ CLI supports compression detection and automatic decompression  
✔ Dry-run mode skips destructive operations (decompression, backup)  
✔ All 10 tests passing: 5 unit tests + 3 resize E2E tests + 2 compression tests

---

## 8. Future Enhancements

- GUI frontend (Electron or Swift)
- Support for GPT‑based Raspberry Pi OS variants
- Verification mode: run `fsck` after each operation
- Image shrink functionality (automatically shrink image to minimum required size)
- **Advanced partition operations**:
  - Automatic partition defragmentation and optimization
  - Support for moving multiple partitions in a single operation
  - Intelligent space allocation based on partition usage
  - Conversion between MBR and GPT partition tables
- **Filesystem features**:
  - Support for additional filesystems (Btrfs, XFS, F2FS)
  - Filesystem UUID and label management
  - Clone and merge multiple image files
- **Performance improvements**:
  - Parallel operations for independent partition modifications
  - Sparse file support for faster cloning
  - Progress tracking with ETA for long operations

---

**End of Document**