# Raspberry Pi Image Resizer (Docker-Based) — Requirements Document

**Version:** 1.0  
**Date:** 2025-11-26  
**Author:** ChatGPT  

This document defines the functional and non-functional requirements for a Docker‑based implementation of a Raspberry Pi disk‑image manipulation and boot‑partition resizing tool.

---

## 1. Purpose

The goal of this project is to provide a **cross‑platform, safe, reproducible** solution for resizing and modifying Raspberry Pi `.img` files using **Linux tools executed inside a Docker container**, while the host system (macOS) simply supplies the image file.

This approach ensures:
- No need for a full Linux VM.
- No macOS filesystem limitations (no native ext4 support).
- Full access to Linux tooling (`losetup`, `parted`, `e2fsck`, `resize2fs`, `mkfs.vfat`, `kpartx`, etc.).
- **Complete partition manipulation capabilities**: The Linux container environment enables moving, resizing, and reorganizing partitions without the restrictions of macOS disk utilities.
- **Advanced filesystem operations**: Direct access to ext4 tools allows safe resizing, checking, and repairing of Linux filesystems.

---

## 2. Scope

The Docker‑based solution shall:

- Accept a Raspberry Pi disk image (`.img`) from the macOS host.
- Create a safety backup before modification.
- Attach the image as a loop device inside a Linux container.
- Examine and manipulate partitions using Linux tools.
- Resize or recreate the boot partition (FAT32).
- Leave the ext4 root filesystem intact unless explicitly requested.
- Output a modified `.img` file on the host.

---

## 3. Definitions

| Term | Definition |
|------|-----------|
| **Boot Partition (p1)** | Typically FAT32 (`W95 FAT32 LBA`), contains Raspberry Pi firmware, overlays, and kernel. |
| **Root Partition (p2)** | ext4 Linux filesystem containing the OS. |
| **Loop Device** | Virtual block device created via `losetup` for accessing partitions inside an image. |
| **Docker Host** | The macOS system running Docker Desktop. |
| **Worker Container** | The Linux environment performing the resizing operations. |

---

## 4. Functional Requirements

### **FR-1: Input Parameters**
The system must accept:

```
resize-image.sh <path-to-image> [--boot-size <MB>] [--unsafe-resize-ext4]
```

- `<path-to-image>` — required; must be a `.img` or raw image.
- `--boot-size <MB>` — optional; default: **256 MB**.
- `--unsafe-resize-ext4` — optional; allows modifying ext4 root partition (disabled by default).

---

### **FR-2: Backup Handling**
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
  - `parted`
  - `fdisk`
  - `losetup`
  - `kpartx`
  - `e2fsprogs` (`e2fsck`, `resize2fs`)
  - `dosfstools` (`mkfs.vfat`)
  - `mount/umount`, `blkid`, `lsblk`

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
   fdisk -l /dev/loop0
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
  - Calculates minimum safe size (used space × 1.2 + 500MB buffer)
  - Automatically shrinks root partition before moving if needed
  - Eliminates the need to manually expand disk images in most cases
- **Moving and resizing partitions** using full Linux container capabilities:
  - Can move the root partition to make room for boot partition expansion
  - Uses `parted move` command to automatically relocate partition data
  - Can resize partitions as long as sufficient disk space exists
  - Uses `parted` for partition boundary manipulation
  - Uses `kpartx` for partition device mapping when needed
  - Falls back to manual `dd` copy if `parted move` fails
- **Recreating FAT32 partition** when required
- **Adjusting partition boundaries** using `parted`:

```
parted /dev/loop0 resizepart 1 <new-end>
parted /dev/loop0 move 2 <new-start>  # Moves both data and partition table entry
```

The Linux container environment enables:
- Full partition table manipulation (MBR/DOS and GPT)
- Moving partitions with automatic data relocation using `parted move`
- Resizing ext4 filesystems online or offline
- Complex multi-partition operations
- Intelligent space optimization based on actual usage
- Fallback to manual data copy with `dd` if needed

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

**Automatic Shrinking (enabled by default when needed):**
When boot partition expansion requires moving the root partition:

- **Check filesystem usage** by mounting and running `df`
- **Calculate minimum safe size**: (used space × 1.2) + 500MB buffer
- **Automatically shrink** if moving would exceed disk capacity:
  ```
  e2fsck -f /dev/loop0p2
  resize2fs /dev/loop0p2 <calculated-size>M
  fdisk - update partition table
  ```
- **Move partition** to new location after shrinking
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
- **Adjust partition boundaries** via `parted`:
  ```
  parted /dev/loop0 resizepart 2 <new-end>
  ```

The Linux container provides full capabilities for:
- Offline ext4 filesystem operations (shrink, expand, check)
- Moving ext4 partitions to different disk locations
- Modifying partition table without data loss (when sufficient space exists)
- Running comprehensive filesystem integrity checks before and after operations
- Intelligent automatic optimization based on actual filesystem usage

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

```
clone-sd.sh clone <output-image-path>
clone-sd.sh write <image-path>
```

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

The write command must:

1. Accept a path to an existing image file
2. Scan for **removable devices ≤ 2TB only** (no Raspberry Pi detection required)
   - Must be removable media
   - Must be ≤ 2TB in size
3. Display a numbered list of all compatible devices (no Pi-specific filtering)
4. Allow interactive selection of the target device
5. Require double confirmation before writing ("yes" and final "WRITE")
6. Unmount any volumes on the target device before writing
7. Write the image to the raw device using `dd` with progress
8. Sync and report success/failure

Safety requirements:
- **Clone command**: Detects Raspberry Pi SD cards specifically to avoid accidental selection of wrong devices
- **Write command**: More permissive device scanning (removable/≤2TB only) but requires double confirmation
- Require explicit user confirmation before starting `dd` operation
- Validate that the selected device meets the operation's criteria (removable media)
- Request confirmation if the output filepath exists (clone only)
- Check for sufficient disk space before cloning (clone only)
- Provide clear warnings about the time required and destructive nature
- Show progress during `dd` operations (press Ctrl+T on macOS)
- For write, require explicit double confirmation due to highly destructive action
- For clone, remount all mountable volumes when done to restore user environment

---

## 5. Non-Functional Requirements

### **NFR-1: Safety**
- Original image must never be modified.
- Ext4 resizing must be opt‑in.
- The tool must abort on:
  - overlapping partitions,
  - corrupted MBR/GPT,
  - missing loop device support.

### **NFR-2: Portability**
Must work on:

- macOS 13 (Ventura)
- macOS 14 (Sonoma)
- macOS 15 (Sequoia)
- Intel and Apple Silicon architectures

### **NFR-3: Reproducibility**
- Docker image versions must be pinned (e.g., Ubuntu 24.04).
- All commands executed inside container must be logged (verbose mode).

### **NFR-4: Usability**
Tool must:

- Display clear progress messages
- Fail with meaningful error messages
- Provide a `--dry-run` mode for previewing changes

### **NFR-5: Maintainability**
- Must be structured as:
  - `Dockerfile`  
  - `resize-image.sh` (host launcher script)  
  - `/container/resize-worker.sh` (internal script)

---

## 6. Risks & Limitations

- Docker on macOS cannot access raw block devices (e.g., `/dev/disk2`) — only `.img` files.
  - **Workaround**: Use `clone-sd.sh` to first clone SD card to `.img` file, then manipulate the image.
- FAT resizing is destructive; partition files must be backed up and restored.
- Some images may have unusual partition layouts (NOOBS, multi-boot).
- **Partition movement operations**:
  - Moving partitions requires sufficient free space on the disk image.
  - **Automatic optimization**: The tool detects when shrinking root before moving eliminates the need for image expansion.
  - Uses `parted move` to automatically relocate both partition table and filesystem data.
  - Falls back to `dd` for manual data copy if `parted move` is unavailable or fails.
  - Moving ext4 partitions is safe but time-consuming for large filesystems (can take 10+ minutes for 10GB+).
  - Most boot expansion operations complete without requiring manual disk image expansion.
- **Filesystem resizing constraints**:
  - ext4 can only be shrunk to the size of its current data usage (plus 20% safety buffer and 500MB).
  - FAT32 partitions must be recreated to resize (data backup/restore required).
  - Filesystem check (`e2fsck`) is mandatory before shrinking ext4 partitions.
  - Automatic shrinking only occurs when necessary to fit partitions within existing disk space.

---

## 7. Acceptance Criteria

✔ Running `resize-image.sh` creates a backup of the input image  
✔ Boot partition enlarges to the requested size  
✔ Boot files are preserved  
✔ Root partition remains intact unless explicitly modified  
✔ The output image boots successfully on a Raspberry Pi  
✔ Docker logs show all commands executed inside the container  
✔ Running `clone-sd.sh` detects Raspberry Pi SD cards and clones them to image files  
✔ SD card detection correctly identifies devices with `cmdline.txt`  
✔ User can select device by index number  
✔ Cloned image is bootable and identical to source SD card

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