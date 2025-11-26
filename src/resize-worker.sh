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
    
    # Remove kpartx mappings
    for loop in $(losetup -j "/work/$IMAGE_FILE" 2>/dev/null | cut -d: -f1); do
        log_debug "Removing kpartx mappings for: $loop"
        kpartx -dv "$loop" 2>/dev/null || true
    done
    
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

if [[ "$DRY_RUN" != "1" ]]; then
    # Set up loop device with partition scanning enabled (-P flag)
    LOOP_DEVICE=$(losetup -f --show -P "/work/$IMAGE_FILE")
    
    if [[ -z "$LOOP_DEVICE" ]]; then
        log_error "Failed to create loop device"
        exit 1
    fi
    
    log_info "Loop device created: $LOOP_DEVICE"
    
    # Force kernel to re-read partition table
    partprobe "$LOOP_DEVICE" 2>/dev/null || true
    
    # Wait for partition devices to appear
    sleep 2
    
    # Use kpartx to map partitions if they don't appear automatically
    if [[ ! -e "${LOOP_DEVICE}p1" ]]; then
        log_debug "Partitions not found, using kpartx..."
        kpartx -av "$LOOP_DEVICE" || true
        sleep 1
    fi
else
    log_debug "Dry run - loop device creation skipped"
    LOOP_DEVICE="/dev/loop0"
fi

# Step 2: Examine partition layout
log_info "Step 2: Examining partition layout..."

if [[ "$DRY_RUN" != "1" ]]; then
    log_debug "Partition table:"
    fdisk -l "$LOOP_DEVICE" || true
    echo ""
    
    # Check if partitions are detected
    if [[ -e "${LOOP_DEVICE}p1" ]]; then
        BOOT_PART="${LOOP_DEVICE}p1"
        ROOT_PART="${LOOP_DEVICE}p2"
    elif [[ -e "/dev/mapper/$(basename ${LOOP_DEVICE})p1" ]]; then
        log_info "Using kpartx mapper devices"
        BOOT_PART="/dev/mapper/$(basename ${LOOP_DEVICE})p1"
        ROOT_PART="/dev/mapper/$(basename ${LOOP_DEVICE})p2"
    else
        log_error "Boot partition not found: ${LOOP_DEVICE}p1"
        log_info "Available devices:"
        ls -la "${LOOP_DEVICE}"* /dev/mapper/ 2>/dev/null || true
        exit 1
    fi
    
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
    # Get current partition information
    BOOT_START=$(fdisk -l "$LOOP_DEVICE" | grep "${LOOP_DEVICE}p1" | awk '{print $2}')
    BOOT_CURRENT_END=$(fdisk -l "$LOOP_DEVICE" | grep "${LOOP_DEVICE}p1" | awk '{print $3}')
    ROOT_START=$(fdisk -l "$LOOP_DEVICE" | grep "${LOOP_DEVICE}p2" | awk '{print $2}')
    ROOT_END=$(fdisk -l "$LOOP_DEVICE" | grep "${LOOP_DEVICE}p2" | awk '{print $3}')
    DISK_SIZE_SECTORS=$(fdisk -l "$LOOP_DEVICE" | grep "^Disk $LOOP_DEVICE" | awk '{print $7}')
    
    BOOT_CURRENT_SIZE_SECTORS=$((BOOT_CURRENT_END - BOOT_START + 1))
    BOOT_CURRENT_SIZE_MB=$((BOOT_CURRENT_SIZE_SECTORS * 512 / 1024 / 1024))
    ROOT_SIZE_SECTORS=$((ROOT_END - ROOT_START + 1))
    ROOT_SIZE_MB=$((ROOT_SIZE_SECTORS * 512 / 1024 / 1024))
    DISK_SIZE_MB=$((DISK_SIZE_SECTORS * 512 / 1024 / 1024))
    
    log_info "Current layout:"
    log_info "  Boot: ${BOOT_CURRENT_SIZE_MB}MB (sectors ${BOOT_START}-${BOOT_CURRENT_END})"
    log_info "  Root: ${ROOT_SIZE_MB}MB (sectors ${ROOT_START}-${ROOT_END})"
    log_info "  Disk: ${DISK_SIZE_MB}MB (${DISK_SIZE_SECTORS} sectors)"
    
    # Check if boot is already large enough
    if [[ $BOOT_CURRENT_SIZE_MB -ge $BOOT_SIZE_MB ]]; then
        log_info "Boot partition is already ${BOOT_CURRENT_SIZE_MB}MB (>= ${BOOT_SIZE_MB}MB)"
        log_info "No resizing needed"
        exit 0
    fi
    
    BOOT_NEW_END=$((BOOT_START + BOOT_SIZE_SECTORS - 1))
    
    log_debug "Boot partition new end would be: sector $BOOT_NEW_END"
    log_debug "Root partition currently starts at: sector $ROOT_START"
    
    # Determine if we need to move the root partition
    NEEDS_ROOT_MOVE=false
    NEEDS_ROOT_SHRINK=false
    ROOT_MOVE_REQUIRED_SECTORS=0
    
    if [[ $BOOT_NEW_END -ge $ROOT_START ]]; then
        NEEDS_ROOT_MOVE=true
        
        # Check if root filesystem can be moved
        if [[ "$ROOT_FS" != "ext4" ]]; then
            log_error "Root partition is not ext4 (detected: $ROOT_FS)"
            log_error "Moving non-ext4 partitions is not supported"
            exit 1
        fi
        
        # Calculate how much we need to move root partition
        # Add 2048 sectors (1MB) alignment buffer
        ROOT_MOVE_REQUIRED_SECTORS=$((BOOT_NEW_END - ROOT_START + 2048))
        ROOT_NEW_START=$(( (BOOT_NEW_END + 2048) / 2048 * 2048 ))  # Align to 1MB boundary
        
        log_warn "Boot partition expansion requires moving root partition"
        log_info "Root partition will be moved from sector $ROOT_START to $ROOT_NEW_START"
        
        # Check root filesystem usage to determine if we can shrink it
        log_info "Checking root filesystem usage..."
        
        mkdir -p /mnt/root
        mount "$ROOT_PART" /mnt/root
        
        ROOT_FS_USED_KB=$(df -k /mnt/root | tail -1 | awk '{print $3}')
        ROOT_FS_SIZE_KB=$(df -k /mnt/root | tail -1 | awk '{print $2}')
        ROOT_FS_USED_MB=$((ROOT_FS_USED_KB / 1024))
        ROOT_FS_FREE_MB=$(((ROOT_FS_SIZE_KB - ROOT_FS_USED_KB) / 1024))
        
        log_info "Root filesystem: ${ROOT_FS_USED_MB}MB used, ${ROOT_FS_FREE_MB}MB free of ${ROOT_SIZE_MB}MB"
        
        umount /mnt/root
        
        # Calculate minimum required root partition size (add 20% buffer + 500MB for safety)
        MIN_ROOT_SIZE_MB=$((ROOT_FS_USED_MB * 120 / 100 + 500))
        
        log_info "Minimum root partition size: ${MIN_ROOT_SIZE_MB}MB (with 20% buffer + 500MB)"
        
        # Calculate new root end if we keep current size
        ROOT_NEW_END_FULL_SIZE=$((ROOT_NEW_START + ROOT_SIZE_SECTORS - 1))
        
        # Check if keeping full size would exceed disk
        if [[ $ROOT_NEW_END_FULL_SIZE -gt $((DISK_SIZE_SECTORS - 1)) ]]; then
            # We need to shrink root to fit
            NEEDS_ROOT_SHRINK=true
            
            # Calculate max possible root size
            MAX_ROOT_SIZE_SECTORS=$((DISK_SIZE_SECTORS - ROOT_NEW_START))
            MAX_ROOT_SIZE_MB=$((MAX_ROOT_SIZE_SECTORS * 512 / 1024 / 1024))
            
            log_warn "Root partition must be shrunk to fit on disk"
            log_info "Maximum root size after move: ${MAX_ROOT_SIZE_MB}MB"
            
            if [[ $MAX_ROOT_SIZE_MB -lt $MIN_ROOT_SIZE_MB ]]; then
                SPACE_NEEDED_MB=$((MIN_ROOT_SIZE_MB - MAX_ROOT_SIZE_MB))
                log_error "Insufficient space on disk image"
                log_error "Root filesystem needs at least ${MIN_ROOT_SIZE_MB}MB (currently using ${ROOT_FS_USED_MB}MB)"
                log_error "After moving root partition, only ${MAX_ROOT_SIZE_MB}MB available"
                log_error "Shortage: ${SPACE_NEEDED_MB}MB"
                log_error ""
                log_error "Options:"
                log_error "  1. Free up ${SPACE_NEEDED_MB}MB on the root partition"
                log_error "  2. Use a smaller boot size (current target: ${BOOT_SIZE_MB}MB)"
                exit 1
            fi
            
            # Target: max available minus 100MB buffer
            TARGET_ROOT_SIZE_MB=$((MAX_ROOT_SIZE_MB - 100))
            ROOT_NEW_SIZE_SECTORS=$((TARGET_ROOT_SIZE_MB * 1024 * 1024 / 512))
            ROOT_NEW_END=$((ROOT_NEW_START + ROOT_NEW_SIZE_SECTORS - 1))
            
            log_info "Will shrink root from ${ROOT_SIZE_MB}MB to ${TARGET_ROOT_SIZE_MB}MB"
        else
            # Can keep full size
            ROOT_NEW_END=$ROOT_NEW_END_FULL_SIZE
            ROOT_NEW_SIZE_SECTORS=$ROOT_SIZE_SECTORS
            
            log_info "Root partition can keep current size (${ROOT_SIZE_MB}MB)"
        fi
    else
        GAP_SECTORS=$((ROOT_START - BOOT_NEW_END - 1))
        GAP_MB=$((GAP_SECTORS * 512 / 1024 / 1024))
        log_info "Boot partition can expand without moving root"
        log_info "Gap between partitions after resize: ${GAP_MB}MB (${GAP_SECTORS} sectors)"
    fi
else
    log_debug "Dry run - partition calculation skipped"
    BOOT_START=8192
    BOOT_NEW_END=$((BOOT_START + BOOT_SIZE_SECTORS - 1))
    NEEDS_ROOT_MOVE=false
    NEEDS_ROOT_SHRINK=false
fi

# Step 5: Shrink root partition if necessary
if [[ "$NEEDS_ROOT_SHRINK" == "true" ]]; then
    log_info "Step 5: Shrinking root partition..."
    
    if [[ "$DRY_RUN" != "1" ]]; then
        # Check filesystem before shrinking
        log_info "Running filesystem check before shrinking..."
        e2fsck -f -y "$ROOT_PART" || {
            log_error "Filesystem check failed - cannot safely shrink partition"
            exit 1
        }
        
        # Shrink filesystem first
        log_info "Shrinking filesystem to ${TARGET_ROOT_SIZE_MB}MB..."
        resize2fs "$ROOT_PART" "${TARGET_ROOT_SIZE_MB}M" || {
            log_error "Filesystem shrink failed"
            exit 1
        }
        
        # Update partition table with new size
        log_info "Updating partition table with new size..."
        NEW_ROOT_END_SHRUNK=$((ROOT_START + ROOT_NEW_SIZE_SECTORS - 1))
        
        {
            echo d      # delete partition
            echo 2      # partition 2
            echo n      # new partition
            echo p      # primary
            echo 2      # partition number
            echo $ROOT_START  # keep current start
            echo $NEW_ROOT_END_SHRUNK    # new end sector
            echo w      # write changes
        } | fdisk "$LOOP_DEVICE" > /dev/null 2>&1
        
        # Reread partition table
        partprobe "$LOOP_DEVICE" 2>/dev/null || true
        kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
        kpartx -av "$LOOP_DEVICE" 2>/dev/null || true
        sleep 2
        
        # Update ROOT_PART reference if using mapper
        if [[ "$ROOT_PART" == "/dev/mapper/"* ]]; then
            ROOT_PART="/dev/mapper/$(basename ${LOOP_DEVICE})p2"
        else
            ROOT_PART="${LOOP_DEVICE}p2"
        fi
        
        # Verify filesystem after partition resize
        e2fsck -f -y "$ROOT_PART" || {
            log_error "Filesystem check failed after partition resize"
            exit 1
        }
        
        log_info "Root partition shrunk successfully to ${TARGET_ROOT_SIZE_MB}MB"
        
        # Update ROOT_END for subsequent operations
        ROOT_END=$NEW_ROOT_END_SHRUNK
        ROOT_SIZE_SECTORS=$ROOT_NEW_SIZE_SECTORS
        ROOT_SIZE_MB=$TARGET_ROOT_SIZE_MB
    else
        log_debug "Dry run - root partition shrink skipped"
    fi
else
    log_info "Step 5: Root partition does not need to be shrunk"
fi

# Step 5b: Move root partition if necessary
if [[ "$NEEDS_ROOT_MOVE" == "true" ]]; then
    log_info "Step 5b: Moving root partition..."
    log_warn "This may take several minutes depending on partition size..."
    
    if [[ "$DRY_RUN" != "1" ]]; then
        # Check filesystem before moving
        log_info "Running filesystem check before moving..."
        e2fsck -f -y "$ROOT_PART" || {
            log_error "Filesystem check failed - cannot safely move partition"
            exit 1
        }
        
        # Calculate new position in MB (parted uses MB)
        ROOT_NEW_START_MB=$((ROOT_NEW_START * 512 / 1024 / 1024))
        ROOT_NEW_END_MB=$((ROOT_NEW_END * 512 / 1024 / 1024))
        
        log_info "Moving partition 2 to ${ROOT_NEW_START_MB}MB-${ROOT_NEW_END_MB}MB..."
        
        # Use parted to move the partition (this moves both partition table entry and data)
        parted -s "$LOOP_DEVICE" unit s move 2 ${ROOT_NEW_START} || {
            log_error "Failed to move root partition with parted"
            log_info "Attempting manual move with dd..."
            
            # Fallback: manual copy with dd
            OLD_ROOT_START=$ROOT_START
            COPY_SIZE_MB=$((ROOT_SIZE_MB))
            
            log_info "Copying ${COPY_SIZE_MB}MB from sector ${OLD_ROOT_START} to ${ROOT_NEW_START}..."
            
            dd if="$LOOP_DEVICE" of="$LOOP_DEVICE" \
               bs=1M \
               skip=$((OLD_ROOT_START * 512 / 1024 / 1024)) \
               seek=$((ROOT_NEW_START * 512 / 1024 / 1024)) \
               count=${COPY_SIZE_MB} \
               conv=notrunc,fsync \
               status=progress || {
                   log_error "Failed to copy partition data"
                   exit 1
               }
            
            # Update partition table after manual copy
            {
                echo d      # delete partition
                echo 2      # partition 2
                echo n      # new partition
                echo p      # primary
                echo 2      # partition number
                echo $ROOT_NEW_START  # new start sector
                echo $ROOT_NEW_END    # new end sector
                echo w      # write changes
            } | fdisk "$LOOP_DEVICE" > /dev/null 2>&1
        }
        
        # Reread partition table
        partprobe "$LOOP_DEVICE" 2>/dev/null || true
        kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
        kpartx -av "$LOOP_DEVICE" 2>/dev/null || true
        sleep 2
        
        # Update ROOT_PART reference if using mapper
        if [[ "$ROOT_PART" == "/dev/mapper/"* ]]; then
            ROOT_PART="/dev/mapper/$(basename ${LOOP_DEVICE})p2"
        else
            ROOT_PART="${LOOP_DEVICE}p2"
        fi
        
        log_info "Root partition moved to new location"
        log_info "New location: sectors ${ROOT_NEW_START}-${ROOT_NEW_END}"
        
        # Run filesystem check and resize to fill new partition
        log_info "Verifying filesystem after move..."
        e2fsck -f -y "$ROOT_PART" || {
            log_error "Filesystem check failed after move"
            exit 1
        }
        
        # Expand filesystem if partition grew
        if [[ $ROOT_NEW_END -gt $ROOT_END ]]; then
            log_info "Expanding filesystem to fill new partition..."
            resize2fs "$ROOT_PART" || {
                log_error "Filesystem resize failed after move"
                exit 1
            }
        fi
        
        log_info "Root partition move completed successfully"
    else
        log_debug "Dry run - root partition move skipped"
    fi
else
    log_info "Step 5b: Root partition does not need to be moved"
fi

# Step 6: Resize boot partition
log_info "Step 6: Resizing boot partition..."

if [[ "$DRY_RUN" != "1" ]]; then
    # Delete and recreate partition 1 with new size
    log_debug "Recreating partition table entry for boot partition..."
    
    # Use fdisk to delete and recreate boot partition
    {
        echo d      # delete partition
        echo 1      # partition 1
        echo n      # new partition
        echo p      # primary
        echo 1      # partition number
        echo $BOOT_START  # start sector
        echo $BOOT_NEW_END    # end sector
        echo t      # change type
        echo 1      # partition 1
        echo c      # W95 FAT32 (LBA)
        echo w      # write changes
    } | fdisk "$LOOP_DEVICE" > /dev/null 2>&1
    
    # Reread partition table
    partprobe "$LOOP_DEVICE" 2>/dev/null || true
    kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
    kpartx -av "$LOOP_DEVICE" 2>/dev/null || true
    sleep 2
    
    # Update BOOT_PART reference if using mapper
    if [[ "$BOOT_PART" == "/dev/mapper/"* ]]; then
        BOOT_PART="/dev/mapper/$(basename ${LOOP_DEVICE})p1"
    else
        BOOT_PART="${LOOP_DEVICE}p1"
    fi
    
    log_info "Partition table updated"
    log_info "New boot partition size: ${BOOT_SIZE_MB}MB"
else
    log_debug "Dry run - partition resize skipped"
fi

# Step 7: Create new FAT32 filesystem
log_info "Step 7: Creating new FAT32 filesystem on boot partition..."

if [[ "$DRY_RUN" != "1" ]]; then
    log_debug "Running mkfs.vfat on $BOOT_PART"
    mkfs.vfat -F 32 "$BOOT_PART"
    
    log_info "FAT32 filesystem created"
else
    log_debug "Dry run - filesystem creation skipped"
fi

# Step 8: Restore boot files
log_info "Step 8: Restoring boot files..."

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

# Step 9: Optional ext4 resize (if enabled and not already done)
if [[ "$UNSAFE_RESIZE_EXT4" == "1" ]] && [[ "$NEEDS_ROOT_MOVE" != "true" ]]; then
    log_warn "Step 9: Resizing ext4 root partition (UNSAFE MODE)..."
    
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
elif [[ "$NEEDS_ROOT_MOVE" == "true" ]]; then
    log_info "Step 9: Root partition already resized during move operation"
else
    log_info "Step 9: Skipping ext4 resize (not requested)"
fi

# Final verification
log_info "Step 10: Final verification..."

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
