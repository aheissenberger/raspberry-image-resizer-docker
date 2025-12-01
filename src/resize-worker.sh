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
IMAGE_SIZE="${IMAGE_SIZE:-}"
UNSAFE_RESIZE_EXT4="${UNSAFE_RESIZE_EXT4:-0}"
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"

log_info "=== Raspberry Pi Image Resizer Worker ==="
log_info "Image file: $IMAGE_FILE"
log_info "Target boot size: ${BOOT_SIZE_MB}MB"
[[ -n "$IMAGE_SIZE" ]] && log_info "Target image size: $IMAGE_SIZE"
[[ "$UNSAFE_RESIZE_EXT4" == "1" ]] && log_warn "Unsafe ext4 resizing enabled"
[[ "$DRY_RUN" == "1" ]] && log_warn "DRY RUN mode active"

# Step 0: Resize image file if requested (before any other operations)
if [[ -n "$IMAGE_SIZE" ]]; then
    log_info "Step 0: Adjusting image file size..."
    
    # Parse target size and convert to bytes
    TARGET_SIZE_BYTES=0
    if [[ "$IMAGE_SIZE" =~ ^([0-9]+)([MGT]B?)$ ]]; then
        SIZE_NUM="${BASH_REMATCH[1]}"
        SIZE_UNIT="${BASH_REMATCH[2]}"
        
        case "${SIZE_UNIT^^}" in
            M|MB)
                TARGET_SIZE_BYTES=$((SIZE_NUM * 1024 * 1024))
                ;;
            G|GB)
                TARGET_SIZE_BYTES=$((SIZE_NUM * 1024 * 1024 * 1024))
                ;;
            T|TB)
                TARGET_SIZE_BYTES=$((SIZE_NUM * 1024 * 1024 * 1024 * 1024))
                ;;
            *)
                log_error "Invalid size unit: $SIZE_UNIT (use MB, GB, or TB)"
                exit 1
                ;;
        esac
    else
        log_error "Invalid size format: $IMAGE_SIZE (use format: 32GB, 64GB, etc.)"
        exit 1
    fi
    
    # Validate target size is reasonable
    if [[ $TARGET_SIZE_BYTES -lt $((100 * 1024 * 1024)) ]]; then
        log_error "Target size too small (minimum 100MB)"
        exit 1
    fi
    
    if [[ $TARGET_SIZE_BYTES -gt $((10 * 1024 * 1024 * 1024 * 1024)) ]]; then
        log_error "Target size too large (maximum 10TB)"
        exit 1
    fi
    
    # Get current image size
    CURRENT_SIZE_BYTES=$(stat -c%s "/work/$IMAGE_FILE" 2>/dev/null || stat -f%z "/work/$IMAGE_FILE" 2>/dev/null)
    CURRENT_SIZE_MB=$((CURRENT_SIZE_BYTES / 1024 / 1024))
    TARGET_SIZE_MB=$((TARGET_SIZE_BYTES / 1024 / 1024))
    
    log_info "Current image size: ${CURRENT_SIZE_MB}MB"
    log_info "Target image size: ${TARGET_SIZE_MB}MB"
    
    if [[ $TARGET_SIZE_BYTES -eq $CURRENT_SIZE_BYTES ]]; then
        log_info "Image already at target size"
    elif [[ $TARGET_SIZE_BYTES -gt $CURRENT_SIZE_BYTES ]]; then
        # Expanding image
        EXPANSION_MB=$((TARGET_SIZE_MB - CURRENT_SIZE_MB))
        log_info "Expanding image by ${EXPANSION_MB}MB..."
        
        if [[ "$DRY_RUN" != "1" ]]; then
            # Check available disk space
            AVAILABLE_KB=$(df -k /work | tail -1 | awk '{print $4}')
            REQUIRED_KB=$((EXPANSION_MB * 1024))
            
            if [[ $AVAILABLE_KB -lt $REQUIRED_KB ]]; then
                log_error "Insufficient disk space. Need ${REQUIRED_KB}KB, have ${AVAILABLE_KB}KB"
                exit 1
            fi
            
            truncate -s "$TARGET_SIZE_BYTES" "/work/$IMAGE_FILE" || {
                log_error "Failed to expand image file"
                exit 1
            }
            
            log_info "Image expanded successfully"
        else
            log_debug "Dry run - image expansion skipped"
        fi
        
        IMAGE_WAS_EXPANDED=true
    else
        # Shrinking image - need to validate partitions first
        log_warn "Shrinking image - validating partition boundaries..."
        
        if [[ "$DRY_RUN" != "1" ]]; then
            # Temporarily attach to check partition table
            TEMP_LOOP=$(losetup -f --show "/work/$IMAGE_FILE")
            
            # Get partition table and find last partition end
            LAST_SECTOR=0
            while read line; do
                if [[ "$line" =~ start=[[:space:]]*([0-9]+).*size=[[:space:]]*([0-9]+) ]]; then
                    START="${BASH_REMATCH[1]}"
                    SIZE="${BASH_REMATCH[2]}"
                    END=$((START + SIZE - 1))
                    if [[ $END -gt $LAST_SECTOR ]]; then
                        LAST_SECTOR=$END
                    fi
                fi
            done < <(sfdisk -d "$TEMP_LOOP" 2>/dev/null)
            
            losetup -d "$TEMP_LOOP"
            
            # Add 10MB safety margin (20480 sectors)
            MIN_REQUIRED_SECTORS=$((LAST_SECTOR + 20480))
            MIN_REQUIRED_BYTES=$((MIN_REQUIRED_SECTORS * 512))
            MIN_REQUIRED_MB=$((MIN_REQUIRED_BYTES / 1024 / 1024))
            
            log_debug "Last partition ends at sector $LAST_SECTOR"
            log_debug "Minimum required size: ${MIN_REQUIRED_MB}MB (with 10MB safety margin)"
            
            if [[ $TARGET_SIZE_BYTES -lt $MIN_REQUIRED_BYTES ]]; then
                SHORTAGE_MB=$((MIN_REQUIRED_MB - TARGET_SIZE_MB))
                log_error "Cannot shrink image below partition boundaries"
                log_error "Minimum required: ${MIN_REQUIRED_MB}MB"
                log_error "Requested target: ${TARGET_SIZE_MB}MB"
                log_error "Shortage: ${SHORTAGE_MB}MB"
                exit 1
            fi
            
            SHRINK_MB=$((CURRENT_SIZE_MB - TARGET_SIZE_MB))
            log_info "Shrinking image by ${SHRINK_MB}MB..."
            
            truncate -s "$TARGET_SIZE_BYTES" "/work/$IMAGE_FILE" || {
                log_error "Failed to shrink image file"
                exit 1
            }
            
            log_info "Image shrunk successfully"
        else
            log_debug "Dry run - image shrinking skipped"
        fi
        
        IMAGE_WAS_SHRUNK=true
    fi
else
    IMAGE_WAS_EXPANDED=false
    IMAGE_WAS_SHRUNK=false
fi

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
    log_debug "Partition table (sfdisk dump):"
    sfdisk -d "$LOOP_DEVICE" || true
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
    pt_dump=$(sfdisk -d "$LOOP_DEVICE" 2>/dev/null || true)
    p1_line=$(echo "$pt_dump" | grep -E '^/dev/.+p1[[:space:]]:')
    p2_line=$(echo "$pt_dump" | grep -E '^/dev/.+p2[[:space:]]:')
    BOOT_START=$(echo "$p1_line" | sed -n 's/.*start=\s*\([0-9]\+\),.*/\1/p')
    BOOT_SIZE_SECTORS_ACTUAL=$(echo "$p1_line" | sed -n 's/.*size=\s*\([0-9]\+\),.*/\1/p')
    ROOT_START=$(echo "$p2_line" | sed -n 's/.*start=\s*\([0-9]\+\),.*/\1/p')
    ROOT_SIZE_SECTORS_ACTUAL=$(echo "$p2_line" | sed -n 's/.*size=\s*\([0-9]\+\),.*/\1/p')
    
    if [[ -z "$BOOT_START" || -z "$BOOT_SIZE_SECTORS_ACTUAL" || -z "$ROOT_START" || -z "$ROOT_SIZE_SECTORS_ACTUAL" ]]; then
        log_error "Failed to parse partition table via sfdisk"
        log_debug "sfdisk dump:\n$pt_dump"
        exit 1
    fi
    BOOT_CURRENT_END=$((BOOT_START + BOOT_SIZE_SECTORS_ACTUAL - 1))
    ROOT_END=$((ROOT_START + ROOT_SIZE_SECTORS_ACTUAL - 1))

    # Sanity guard: ensure distinct starts parsed from sfdisk dump
    if [[ "$BOOT_START" == "$ROOT_START" ]]; then
        log_error "Parsed BOOT_START and ROOT_START are equal ($BOOT_START) — invalid layout parsing"
        log_debug "sfdisk dump:\n$pt_dump"
        exit 1
    fi

    # Validate fallback success
    for v in BOOT_START BOOT_CURRENT_END ROOT_START ROOT_END; do
        if [[ -z "${!v}" ]]; then
            log_error "Failed to determine partition metric: $v"
            exit 1
        fi
    done
    # Get total disk sectors without fdisk (blockdev reports 512-byte sectors)
    DISK_SIZE_SECTORS=$(blockdev --getsz "$LOOP_DEVICE")

    log_debug "Parsed metrics: BOOT_START=${BOOT_START} BOOT_CURRENT_END=${BOOT_CURRENT_END} ROOT_START=${ROOT_START} ROOT_END=${ROOT_END} DISK_SIZE_SECTORS=${DISK_SIZE_SECTORS}"
    
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
        # Calculate minimum required root partition size (20% headroom + 100MB buffer)
        MIN_ROOT_SIZE_MB=$((ROOT_FS_USED_MB * 120 / 100 + 100))
        
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
    log_info "Step 5: Shrinking root partition (sfdisk)..."

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

        # Prepare new partition table (boot unchanged, root smaller)
        NEW_ROOT_END_SHRUNK=$((ROOT_START + ROOT_NEW_SIZE_SECTORS - 1))
        CURRENT_BOOT_SIZE_SECTORS=$((BOOT_CURRENT_END - BOOT_START + 1))

        cat > /tmp/shrink-layout.sfdisk <<EOF
label: dos
unit: sectors

${LOOP_DEVICE}p1 : start=${BOOT_START}, size=${CURRENT_BOOT_SIZE_SECTORS}, type=c, bootable
${LOOP_DEVICE}p2 : start=${ROOT_START}, size=${ROOT_NEW_SIZE_SECTORS}, type=83
EOF

        log_debug "Applying shrunk root partition table via sfdisk"
        if ! sfdisk --force --no-reread "$LOOP_DEVICE" < /tmp/shrink-layout.sfdisk 2>/tmp/sfdisk-shrink.log; then
            log_error "sfdisk failed during shrink"
            log_debug "sfdisk shrink output:"; cat /tmp/sfdisk-shrink.log
            exit 1
        fi

        partprobe "$LOOP_DEVICE" 2>/dev/null || true
        blockdev --rereadpt "$LOOP_DEVICE" 2>/dev/null || true
        kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
        kpartx -av "$LOOP_DEVICE" 2>/dev/null || true
        sleep 2

        # Update ROOT_PART reference if using mapper
        if [[ -e "/dev/mapper/$(basename ${LOOP_DEVICE})p2" ]]; then
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

# Step 5b: Move root partition if necessary (overlap-safe)
if [[ "$NEEDS_ROOT_MOVE" == "true" ]]; then
    log_info "Step 5b: Moving root partition..."
    log_warn "This may take several minutes depending on partition size..."

    if [[ "$DRY_RUN" != "1" ]]; then
        # Ensure root not mounted
        if mountpoint -q /mnt/root 2>/dev/null; then
            umount /mnt/root || { log_error "Cannot unmount root before move"; exit 1; }
        fi

        log_info "Running filesystem check before moving..."
        e2fsck -f -y "$ROOT_PART" || { log_error "Filesystem check failed - cannot move"; exit 1; }

        OLD_ROOT_START=$ROOT_START
        OLD_ROOT_END=$ROOT_END
        NEW_ROOT_START=$ROOT_NEW_START
        NEW_ROOT_END=$ROOT_NEW_END
        COPY_SIZE_SECTORS=$ROOT_SIZE_SECTORS

        log_info "Moving partition 2 from sectors ${OLD_ROOT_START}-${OLD_ROOT_END} to ${NEW_ROOT_START}-${NEW_ROOT_END}"

        DEST_END=$((NEW_ROOT_START + COPY_SIZE_SECTORS - 1))
        OVERLAPS=false
        if [[ $NEW_ROOT_START -le $OLD_ROOT_END && $DEST_END -ge $OLD_ROOT_START ]]; then
            OVERLAPS=true
        fi

        if [[ $OVERLAPS == true ]]; then
            log_warn "Source and destination overlap – performing backward copy"
            BLOCK_SECTORS=128
            REMAIN=$COPY_SIZE_SECTORS
            PROGRESS=0
            while [[ $REMAIN -gt 0 ]]; do
                CUR=$(( REMAIN < BLOCK_SECTORS ? REMAIN : BLOCK_SECTORS ))
                OFFSET_FROM_END=$((PROGRESS + CUR))
                SRC_START=$((OLD_ROOT_END - OFFSET_FROM_END + 1))
                DST_START=$((NEW_ROOT_START + (SRC_START - OLD_ROOT_START)))
                dd if="$LOOP_DEVICE" of="$LOOP_DEVICE" bs=512 skip=$SRC_START seek=$DST_START count=$CUR conv=notrunc 2>/dev/null || { log_error "Backward copy failed at sector $SRC_START"; exit 1; }
                PROGRESS=$((PROGRESS + CUR))
                REMAIN=$((REMAIN - CUR))
                if (( PROGRESS % (1024*1024) == 0 )); then
                    PERC=$((PROGRESS * 100 / COPY_SIZE_SECTORS))
                    log_debug "  Backward copy progress: ${PERC}% (${PROGRESS}/${COPY_SIZE_SECTORS} sectors)"
                fi
            done
        else
            log_info "No overlap – forward copy via dd"
            dd if="$LOOP_DEVICE" of="$LOOP_DEVICE" bs=512 skip=$OLD_ROOT_START seek=$NEW_ROOT_START count=$COPY_SIZE_SECTORS conv=notrunc status=progress || { log_error "Forward copy failed"; exit 1; }
        fi

        log_info "Data copy completed"

        log_debug "Removing kpartx mappings..."
        kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
        sleep 1

        log_debug "Detaching loop device..."
        IMAGE_PATH="/work/$IMAGE_FILE"
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
        sleep 1

        log_debug "Re-attaching loop device..."
        LOOP_DEVICE=$(losetup -f --show "$IMAGE_PATH") || { log_error "Failed to reattach loop"; exit 1; }
        log_debug "Reattached loop: $LOOP_DEVICE"
        sleep 1

        NEW_BOOT_SIZE_SECTORS=$((BOOT_NEW_END - BOOT_START + 1))
        NEW_ROOT_SIZE_SECTORS=$((NEW_ROOT_END - NEW_ROOT_START + 1))

        cat > /tmp/new-layout.sfdisk <<EOF
label: dos
label-id: 0x878f53aa
unit: sectors

${LOOP_DEVICE}p1 : start=${BOOT_START}, size=${NEW_BOOT_SIZE_SECTORS}, type=c, bootable
${LOOP_DEVICE}p2 : start=${NEW_ROOT_START}, size=${NEW_ROOT_SIZE_SECTORS}, type=83
EOF

        log_debug "Applying new partition table via sfdisk"
        if ! sfdisk --force --no-reread "$LOOP_DEVICE" < /tmp/new-layout.sfdisk 2>/tmp/sfdisk.log; then
            log_error "sfdisk failed"
            log_debug "sfdisk output:"; cat /tmp/sfdisk.log
            exit 1
        fi

        partprobe "$LOOP_DEVICE" 2>/dev/null || true
        blockdev --rereadpt "$LOOP_DEVICE" 2>/dev/null || true
        sleep 1

        log_debug "Recreating kpartx mappings..."
        kpartx -av "$LOOP_DEVICE" 2>/dev/null || true
        sleep 2

        if [[ -e "/dev/mapper/$(basename ${LOOP_DEVICE})p1" ]]; then
            BOOT_PART="/dev/mapper/$(basename ${LOOP_DEVICE})p1"
            ROOT_PART="/dev/mapper/$(basename ${LOOP_DEVICE})p2"
        else
            BOOT_PART="${LOOP_DEVICE}p1"
            ROOT_PART="${LOOP_DEVICE}p2"
        fi

        [[ -b "$ROOT_PART" ]] || { log_error "Root partition device missing after move"; exit 1; }

        log_info "Root partition now at sectors ${NEW_ROOT_START}-${NEW_ROOT_END}"
        log_info "Verifying filesystem after move..."
        e2fsck -f -y "$ROOT_PART" || { log_error "Filesystem check failed after move"; exit 1; }

        if [[ "$NEEDS_ROOT_SHRINK" == "true" ]]; then
            log_info "Expanding filesystem to fill partition..."
            resize2fs "$ROOT_PART" || { log_error "Final filesystem expansion failed"; exit 1; }
        fi

        log_info "Root partition move completed successfully"
    else
        log_debug "Dry run - root partition move skipped"
    fi
else
    log_info "Step 5b: Root partition does not need to be moved"
fi

# Step 6: Resize boot partition
log_info "Step 6: Resizing boot partition (sfdisk)..."

if [[ "$DRY_RUN" != "1" ]]; then
    NEW_BOOT_SIZE_SECTORS=$((BOOT_NEW_END - BOOT_START + 1))
    # If root was moved, partition table already updated during move step; skip rewrite.
    if [[ "$NEEDS_ROOT_MOVE" == "true" ]]; then
        log_info "Boot partition size already set during root move"
    else
        ROOT_SIZE_SECTORS_FINAL=$((ROOT_END - ROOT_START + 1))
        cat > /tmp/boot-resize.sfdisk <<EOF
label: dos
unit: sectors

${LOOP_DEVICE}p1 : start=${BOOT_START}, size=${NEW_BOOT_SIZE_SECTORS}, type=c, bootable
${LOOP_DEVICE}p2 : start=${ROOT_START}, size=${ROOT_SIZE_SECTORS_FINAL}, type=83
EOF
        log_debug "Applying boot resize partition table via sfdisk"
        if ! sfdisk --force --no-reread "$LOOP_DEVICE" < /tmp/boot-resize.sfdisk 2>/tmp/sfdisk-boot.log; then
            log_error "sfdisk failed during boot resize"
            log_debug "sfdisk boot output:"; cat /tmp/sfdisk-boot.log
            exit 1
        fi
        partprobe "$LOOP_DEVICE" 2>/dev/null || true
        blockdev --rereadpt "$LOOP_DEVICE" 2>/dev/null || true
        kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
        kpartx -av "$LOOP_DEVICE" 2>/dev/null || true
        sleep 2
    fi

    # Update BOOT_PART reference if using mapper
    if [[ -e "/dev/mapper/$(basename ${LOOP_DEVICE})p1" ]]; then
        BOOT_PART="/dev/mapper/$(basename ${LOOP_DEVICE})p1"
    else
        BOOT_PART="${LOOP_DEVICE}p1"
    fi

    log_info "Boot partition size now: ${BOOT_SIZE_MB}MB"
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

# Step 9: Automatic root partition adjustment when image size changed
if [[ "$IMAGE_WAS_EXPANDED" == "true" ]] || [[ "$IMAGE_WAS_SHRUNK" == "true" ]]; then
    log_info "Step 9: Adjusting root partition to use available space..."
    
    if [[ "$DRY_RUN" != "1" ]]; then
        # Get current disk and partition info
        DISK_SIZE_SECTORS=$(blockdev --getsz "$LOOP_DEVICE")
        
        # Parse current root partition boundaries
        pt_dump=$(sfdisk -d "$LOOP_DEVICE" 2>/dev/null || true)
        p2_line=$(echo "$pt_dump" | grep -E '^/dev/.+p2[[:space:]]:')
        CURRENT_ROOT_START=$(echo "$p2_line" | sed -n 's/.*start=\s*\([0-9]\+\),.*/\1/p')
        CURRENT_ROOT_SIZE=$(echo "$p2_line" | sed -n 's/.*size=\s*\([0-9]\+\),.*/\1/p')
        
        if [[ -z "$CURRENT_ROOT_START" || -z "$CURRENT_ROOT_SIZE" ]]; then
            log_error "Failed to parse current root partition boundaries"
            exit 1
        fi
        
        # Calculate maximum available space for root (disk end minus root start, with 2048 sector alignment buffer)
        MAX_ROOT_SIZE_SECTORS=$((DISK_SIZE_SECTORS - CURRENT_ROOT_START - 2048))
        MAX_ROOT_SIZE_MB=$((MAX_ROOT_SIZE_SECTORS * 512 / 1024 / 1024))
        CURRENT_ROOT_SIZE_MB=$((CURRENT_ROOT_SIZE * 512 / 1024 / 1024))
        
        log_debug "Current root: ${CURRENT_ROOT_SIZE_MB}MB (sectors ${CURRENT_ROOT_START}-$((CURRENT_ROOT_START + CURRENT_ROOT_SIZE - 1)))"
        log_debug "Maximum available: ${MAX_ROOT_SIZE_MB}MB"
        
        if [[ "$IMAGE_WAS_EXPANDED" == "true" ]] && [[ $MAX_ROOT_SIZE_SECTORS -gt $CURRENT_ROOT_SIZE ]]; then
            # Expand root partition to use all available space
            EXPANSION_MB=$((MAX_ROOT_SIZE_MB - CURRENT_ROOT_SIZE_MB))
            log_info "Expanding root partition by ${EXPANSION_MB}MB to ${MAX_ROOT_SIZE_MB}MB..."
            
            # Update partition table
            p1_line=$(echo "$pt_dump" | grep -E '^/dev/.+p1[[:space:]]:')
            BOOT_START=$(echo "$p1_line" | sed -n 's/.*start=\s*\([0-9]\+\),.*/\1/p')
            BOOT_SIZE=$(echo "$p1_line" | sed -n 's/.*size=\s*\([0-9]\+\),.*/\1/p')
            
            cat > /tmp/expand-root.sfdisk <<EOF
label: dos
unit: sectors

${LOOP_DEVICE}p1 : start=${BOOT_START}, size=${BOOT_SIZE}, type=c, bootable
${LOOP_DEVICE}p2 : start=${CURRENT_ROOT_START}, size=${MAX_ROOT_SIZE_SECTORS}, type=83
EOF
            
            if ! sfdisk --force --no-reread "$LOOP_DEVICE" < /tmp/expand-root.sfdisk 2>/tmp/sfdisk-expand.log; then
                log_error "Failed to expand root partition table"
                cat /tmp/sfdisk-expand.log
                exit 1
            fi
            
            partprobe "$LOOP_DEVICE" 2>/dev/null || true
            blockdev --rereadpt "$LOOP_DEVICE" 2>/dev/null || true
            kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
            kpartx -av "$LOOP_DEVICE" 2>/dev/null || true
            sleep 2
            
            # Update ROOT_PART reference
            if [[ -e "/dev/mapper/$(basename ${LOOP_DEVICE})p2" ]]; then
                ROOT_PART="/dev/mapper/$(basename ${LOOP_DEVICE})p2"
            else
                ROOT_PART="${LOOP_DEVICE}p2"
            fi
            
            # Expand filesystem
            log_info "Expanding root filesystem to fill partition..."
            e2fsck -f -y "$ROOT_PART" || {
                log_error "Filesystem check failed before expansion"
                exit 1
            }
            
            resize2fs "$ROOT_PART" || {
                log_error "Filesystem expansion failed"
                exit 1
            }
            
            log_info "Root partition expanded successfully to ${MAX_ROOT_SIZE_MB}MB"
            
        elif [[ "$IMAGE_WAS_SHRUNK" == "true" ]] && [[ $MAX_ROOT_SIZE_SECTORS -lt $CURRENT_ROOT_SIZE ]]; then
            # Shrink root partition to fit in available space
            SHRINK_MB=$((CURRENT_ROOT_SIZE_MB - MAX_ROOT_SIZE_MB))
            log_info "Shrinking root partition by ${SHRINK_MB}MB to ${MAX_ROOT_SIZE_MB}MB..."
            
            # Check filesystem usage
            mkdir -p /mnt/root
            mount "$ROOT_PART" /mnt/root
            ROOT_USED_KB=$(df -k /mnt/root | tail -1 | awk '{print $3}')
            ROOT_USED_MB=$((ROOT_USED_KB / 1024))
            umount /mnt/root
            
            MIN_REQUIRED_MB=$((ROOT_USED_MB * 120 / 100 + 100))
            
            if [[ $MAX_ROOT_SIZE_MB -lt $MIN_REQUIRED_MB ]]; then
                log_error "Cannot shrink root partition: insufficient space"
                log_error "Filesystem uses ${ROOT_USED_MB}MB, minimum ${MIN_REQUIRED_MB}MB required"
                log_error "Target size ${MAX_ROOT_SIZE_MB}MB is too small"
                exit 1
            fi
            
            # Shrink filesystem first
            log_info "Shrinking filesystem to ${MAX_ROOT_SIZE_MB}MB..."
            e2fsck -f -y "$ROOT_PART" || {
                log_error "Filesystem check failed before shrinking"
                exit 1
            }
            
            resize2fs "$ROOT_PART" "${MAX_ROOT_SIZE_MB}M" || {
                log_error "Filesystem shrink failed"
                exit 1
            }
            
            # Update partition table
            p1_line=$(echo "$pt_dump" | grep -E '^/dev/.+p1[[:space:]]:')
            BOOT_START=$(echo "$p1_line" | sed -n 's/.*start=\s*\([0-9]\+\),.*/\1/p')
            BOOT_SIZE=$(echo "$p1_line" | sed -n 's/.*size=\s*\([0-9]\+\),.*/\1/p')
            
            cat > /tmp/shrink-root.sfdisk <<EOF
label: dos
unit: sectors

${LOOP_DEVICE}p1 : start=${BOOT_START}, size=${BOOT_SIZE}, type=c, bootable
${LOOP_DEVICE}p2 : start=${CURRENT_ROOT_START}, size=${MAX_ROOT_SIZE_SECTORS}, type=83
EOF
            
            if ! sfdisk --force --no-reread "$LOOP_DEVICE" < /tmp/shrink-root.sfdisk 2>/tmp/sfdisk-shrink.log; then
                log_error "Failed to shrink root partition table"
                cat /tmp/sfdisk-shrink.log
                exit 1
            fi
            
            partprobe "$LOOP_DEVICE" 2>/dev/null || true
            blockdev --rereadpt "$LOOP_DEVICE" 2>/dev/null || true
            kpartx -dv "$LOOP_DEVICE" 2>/dev/null || true
            kpartx -av "$LOOP_DEVICE" 2>/dev/null || true
            sleep 2
            
            log_info "Root partition shrunk successfully to ${MAX_ROOT_SIZE_MB}MB"
            
        else
            log_info "Root partition already optimal for current disk size"
        fi
    else
        log_debug "Dry run - root partition adjustment skipped"
    fi
    
elif [[ "$UNSAFE_RESIZE_EXT4" == "1" ]] && [[ "$NEEDS_ROOT_MOVE" != "true" ]]; then
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
    log_debug "Final partition layout (sfdisk dump):"
    sfdisk -d "$LOOP_DEVICE" || true
    echo ""

    log_debug "Filesystem information:"
    blkid "$BOOT_PART" "$ROOT_PART" || true
else
    log_debug "Dry run - verification skipped"
fi

log_info "=== Operation completed successfully ==="

exit 0
