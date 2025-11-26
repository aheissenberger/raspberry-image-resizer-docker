#!/bin/bash

# Raspberry Pi Image Resizer - Container Worker Script
# Runs inside Docker container with full Linux tools and privileges

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "$VERBOSE" == "1" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

log_command() {
    if [[ "$VERBOSE" == "1" ]]; then
        echo -e "${BLUE}[CMD]${NC} $1"
    fi
}

run_cmd() {
    log_command "$@"
    if [[ "$DRY_RUN" == "1" ]]; then
        log_debug "Dry run - command not executed"
        return 0
    fi
    "$@"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    
    # Unmount any mounted filesystems
    if mountpoint -q /mnt/boot 2>/dev/null; then
        log_debug "Unmounting /mnt/boot"
        umount /mnt/boot 2>/dev/null || true
    fi
    
    if mountpoint -q /mnt/root 2>/dev/null; then
        log_debug "Unmounting /mnt/root"
        umount /mnt/root 2>/dev/null || true
    fi
    
    # Detach loop devices
    for loop in $(losetup -j "/work/$IMAGE_FILE" 2>/dev/null | cut -d: -f1); do
        log_debug "Detaching loop device: $loop"
        losetup -d "$loop" 2>/dev/null || true
    done
    
    # Clean up temporary directories
    rm -rf /boot-backup 2>/dev/null || true
}

# Set trap for cleanup
trap cleanup EXIT

# Validate environment variables
if [[ -z "$IMAGE_FILE" ]]; then
    log_error "IMAGE_FILE environment variable not set"
    exit 1
fi

if [[ ! -f "/work/$IMAGE_FILE" ]]; then
    log_error "Image file not found: /work/$IMAGE_FILE"
    exit 1
fi

# Set defaults
BOOT_SIZE_MB="${BOOT_SIZE_MB:-256}"
UNSAFE_RESIZE_EXT4="${UNSAFE_RESIZE_EXT4:-0}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

log_info "=== Raspberry Pi Image Resizer Worker ==="
log_info "Image file: $IMAGE_FILE"
log_info "Target boot size: ${BOOT_SIZE_MB}MB"
[[ "$UNSAFE_RESIZE_EXT4" == "1" ]] && log_warn "Unsafe ext4 resizing enabled"
[[ "$DRY_RUN" == "1" ]] && log_warn "DRY RUN mode active"

# Step 1: Attach image as loop device
log_info "Step 1: Attaching image as loop device..."
LOOP_DEVICE=$(losetup -f)
log_debug "Available loop device: $LOOP_DEVICE"

if [[ "$DRY_RUN" != "1" ]]; then
    losetup -Pf "/work/$IMAGE_FILE"
    LOOP_DEVICE=$(losetup -j "/work/$IMAGE_FILE" | cut -d: -f1)
    log_info "Loop device created: $LOOP_DEVICE"
    
    # Give kernel time to detect partitions
    sleep 2
    partprobe "$LOOP_DEVICE" 2>/dev/null || true
    sleep 1
else
    log_debug "Dry run - loop device creation skipped"
    LOOP_DEVICE="/dev/loop0"
fi

# Step 2: Examine partition layout
log_info "Step 2: Examining partition layout..."

if [[ "$DRY_RUN" != "1" ]]; then
    log_debug "Partition table:"
    fdisk -l "$LOOP_DEVICE" | grep -E "^Disk|^Device" || true
    echo ""
    
    # Check if partitions are detected
    BOOT_PART="${LOOP_DEVICE}p1"
    ROOT_PART="${LOOP_DEVICE}p2"
    
    if [[ ! -b "$BOOT_PART" ]]; then
        log_error "Boot partition not found: $BOOT_PART"
        exit 1
    fi
    
    if [[ ! -b "$ROOT_PART" ]]; then
        log_error "Root partition not found: $ROOT_PART"
        exit 1
    fi
    
    log_info "Boot partition: $BOOT_PART"
    log_info "Root partition: $ROOT_PART"
    
    # Get partition information
    BOOT_FS=$(blkid -s TYPE -o value "$BOOT_PART" 2>/dev/null || echo "unknown")
    ROOT_FS=$(blkid -s TYPE -o value "$ROOT_PART" 2>/dev/null || echo "unknown")
    
    log_debug "Boot filesystem: $BOOT_FS"
    log_debug "Root filesystem: $ROOT_FS"
    
    if [[ "$BOOT_FS" != "vfat" ]]; then
        log_warn "Boot partition is not FAT32 (detected: $BOOT_FS)"
    fi
    
    if [[ "$ROOT_FS" != "ext4" ]]; then
        log_warn "Root partition is not ext4 (detected: $ROOT_FS)"
    fi
else
    log_debug "Dry run - partition examination skipped"
    BOOT_PART="${LOOP_DEVICE}p1"
    ROOT_PART="${LOOP_DEVICE}p2"
fi

# Step 3: Backup boot partition files
log_info "Step 3: Backing up boot partition files..."

if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p /mnt/boot
    mkdir -p /boot-backup
    
    mount "$BOOT_PART" /mnt/boot
    log_debug "Boot partition mounted"
    
    log_debug "Copying boot files..."
    rsync -a /mnt/boot/ /boot-backup/
    
    BOOT_FILE_COUNT=$(find /boot-backup -type f | wc -l)
    log_info "Backed up $BOOT_FILE_COUNT files from boot partition"
    
    umount /mnt/boot
    log_debug "Boot partition unmounted"
else
    log_debug "Dry run - boot backup skipped"
fi

# Step 4: Calculate new partition layout
log_info "Step 4: Calculating new partition layout..."

BOOT_SIZE_BYTES=$((BOOT_SIZE_MB * 1024 * 1024))
BOOT_SIZE_SECTORS=$((BOOT_SIZE_BYTES / 512))

if [[ "$DRY_RUN" != "1" ]]; then
    # Get current partition start sector
    BOOT_START=$(fdisk -l "$LOOP_DEVICE" | grep "${LOOP_DEVICE}p1" | awk '{print $2}')
    ROOT_START=$(fdisk -l "$LOOP_DEVICE" | grep "${LOOP_DEVICE}p2" | awk '{print $2}')
    
    BOOT_END=$((BOOT_START + BOOT_SIZE_SECTORS - 1))
    
    log_debug "Boot partition start: sector $BOOT_START"
    log_debug "Boot partition new end: sector $BOOT_END"
    log_debug "Root partition start: sector $ROOT_START"
    
    # Check if new boot partition overlaps with root partition
    if [[ $BOOT_END -ge $ROOT_START ]]; then
        log_error "New boot partition size ($BOOT_SIZE_MB MB) would overlap with root partition"
        log_error "Boot would end at sector $BOOT_END, but root starts at sector $ROOT_START"
        exit 1
    fi
    
    GAP_SECTORS=$((ROOT_START - BOOT_END - 1))
    GAP_MB=$((GAP_SECTORS * 512 / 1024 / 1024))
    log_info "Gap between partitions: ${GAP_MB}MB (${GAP_SECTORS} sectors)"
else
    log_debug "Dry run - partition calculation skipped"
    BOOT_START=8192
    BOOT_END=$((BOOT_START + BOOT_SIZE_SECTORS - 1))
fi

# Step 5: Resize boot partition
log_info "Step 5: Resizing boot partition..."

if [[ "$DRY_RUN" != "1" ]]; then
    # Delete and recreate partition 1 with new size
    log_debug "Recreating partition table entry for boot partition..."
    
    # Use parted to resize partition
    parted -s "$LOOP_DEVICE" resizepart 1 $((BOOT_END * 512))B 2>/dev/null || {
        log_warn "parted resizepart failed, using fdisk approach..."
        
        # Alternative: use fdisk to delete and recreate
        {
            echo d      # delete partition
            echo 1      # partition 1
            echo n      # new partition
            echo p      # primary
            echo 1      # partition number
            echo $BOOT_START  # start sector
            echo $BOOT_END    # end sector
            echo t      # change type
            echo 1      # partition 1
            echo c      # W95 FAT32 (LBA)
            echo w      # write changes
        } | fdisk "$LOOP_DEVICE" > /dev/null 2>&1
    }
    
    # Reread partition table
    partprobe "$LOOP_DEVICE" 2>/dev/null || true
    sleep 2
    
    log_info "Partition table updated"
else
    log_debug "Dry run - partition resize skipped"
fi

# Step 6: Create new FAT32 filesystem
log_info "Step 6: Creating new FAT32 filesystem on boot partition..."

if [[ "$DRY_RUN" != "1" ]]; then
    log_debug "Running mkfs.vfat on $BOOT_PART"
    mkfs.vfat -F 32 "$BOOT_PART"
    
    log_info "FAT32 filesystem created"
else
    log_debug "Dry run - filesystem creation skipped"
fi

# Step 7: Restore boot files
log_info "Step 7: Restoring boot files..."

if [[ "$DRY_RUN" != "1" ]]; then
    mount "$BOOT_PART" /mnt/boot
    log_debug "Boot partition mounted"
    
    log_debug "Copying files back..."
    rsync -a /boot-backup/ /mnt/boot/
    
    RESTORED_COUNT=$(find /mnt/boot -type f | wc -l)
    log_info "Restored $RESTORED_COUNT files to boot partition"
    
    umount /mnt/boot
    log_debug "Boot partition unmounted"
else
    log_debug "Dry run - file restoration skipped"
fi

# Step 8: Optional ext4 resize (if enabled)
if [[ "$UNSAFE_RESIZE_EXT4" == "1" ]]; then
    log_warn "Step 8: Resizing ext4 root partition (UNSAFE MODE)..."
    
    if [[ "$DRY_RUN" != "1" ]]; then
        log_debug "Running filesystem check on $ROOT_PART"
        e2fsck -f -y "$ROOT_PART" || {
            log_error "Filesystem check failed"
            exit 1
        }
        
        log_debug "Running resize2fs on $ROOT_PART"
        resize2fs "$ROOT_PART" || {
            log_error "Filesystem resize failed"
            exit 1
        }
        
        log_info "Root partition resized successfully"
    else
        log_debug "Dry run - ext4 resize skipped"
    fi
else
    log_info "Step 8: Skipping ext4 resize (not requested)"
fi

# Final verification
log_info "Step 9: Final verification..."

if [[ "$DRY_RUN" != "1" ]]; then
    log_debug "Final partition layout:"
    fdisk -l "$LOOP_DEVICE" | grep -E "^Disk|^Device" || true
    echo ""
    
    log_debug "Filesystem information:"
    blkid "$BOOT_PART" "$ROOT_PART" || true
else
    log_debug "Dry run - verification skipped"
fi

log_info "=== Operation completed successfully ==="

exit 0
