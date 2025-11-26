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
- Full access to Linux tooling (`losetup`, `parted`, `e2fsck`, `resize2fs`, `mkfs.vfat`, etc.).

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

- Expanding boot partition size (if free space exists).
- Recreating FAT32 partition when required.
- Adjusting partition boundaries using `parted`:

```
parted /dev/loop0 resizepart 1 <new-end>
```

If the requested size overlaps with another partition:

- Abort with a clear error
- Do NOT modify the root partition unless `--unsafe-resize-ext4` is provided

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

### **FR-8: (Optional) Root Partition Resize**
Only when `--unsafe-resize-ext4` is explicitly enabled:

- Resize ext4 via `resize2fs`
- Adjust partition boundaries via `parted`
- Run full filesystem checks:
  ```
  e2fsck -f /dev/loop0p2
  ```

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

### **FR-10: SD Card Cloning**
The system must provide a command to clone a Raspberry Pi SD card to an image file:

```
clone-sd.sh <output-image-path>
```

The tool must:

1. Scan all mounted external devices (removable media)
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

Safety requirements:
- Require explicit user confirmation before starting `dd` operation
- Validate that the selected device is actually removable/external
- Request confirmation if the output filepath exists
- Check for sufficient disk space before cloning
- Provide clear warnings about the time required for large SD cards
- Show a progress bar when cloning with `dd`

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
- FAT resizing is destructive; partition files must be backed up and restored.
- Some images may have unusual partition layouts (NOOBS, multi-boot).

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
- Image shrink functionality

---

**End of Document**