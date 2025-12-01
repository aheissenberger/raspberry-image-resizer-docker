#!/bin/bash
set -euo pipefail

# Test script: create a small Pi-like image entirely INSIDE container, then run resize-worker.sh
# Assumptions: running in the built Docker image with required tools, privileged mode.

IMAGE_FILE=${IMAGE_FILE:-"test.img"}
EXPORT_BOOT_TARGET_MB=${BOOT_SIZE_MB:-"256"}   # Target boot size for resize
INITIAL_BOOT_MB="64"                            # Initial boot size to provoke move
INITIAL_IMAGE_MB=${INITIAL_IMAGE_MB:-"700"}    # Initial image size
FREE_TAIL_MB=${FREE_TAIL_MB:-"0"}            # Optional free space at end of disk to allow shrink
TARGET_IMAGE_MB=${TARGET_IMAGE_MB:-""}         # Target image size (if expanding/shrinking)
VERBOSE=${VERBOSE:-"1"}
SNAPSHOT=${SNAPSHOT:-0}

log() { echo "[TEST] $*"; }

cd /work

if [[ -f "$IMAGE_FILE" ]]; then
  log "Removing existing image $IMAGE_FILE"
  rm -f "$IMAGE_FILE"
fi

log "Creating blank image ${INITIAL_IMAGE_MB}MB..."
dd if=/dev/zero of="$IMAGE_FILE" bs=1M count="$INITIAL_IMAGE_MB" status=none

# Attach loop (initial, no partition scan yet)
LOOP=$(losetup -f --show "$IMAGE_FILE")
log "Loop device (initial): $LOOP"

# Calculate sectors
SECTORS_TOTAL=$((INITIAL_IMAGE_MB * 1024 * 1024 / 512))
BOOT_SIZE_SECTORS=$((INITIAL_BOOT_MB * 1024 * 1024 / 512))
FREE_TAIL_SECTORS=$((FREE_TAIL_MB * 1024 * 1024 / 512))
BOOT_START=8192
BOOT_END=$((BOOT_START + BOOT_SIZE_SECTORS - 1))
ROOT_START=$((BOOT_END + 1))
ROOT_END=$((SECTORS_TOTAL - 1 - FREE_TAIL_SECTORS))
ROOT_SIZE_SECTORS=$((ROOT_END - ROOT_START + 1))

if [[ "$FREE_TAIL_MB" != "0" ]]; then
  log "Writing initial partition table (boot ${INITIAL_BOOT_MB}MB, root rest, free tail ${FREE_TAIL_MB}MB)..."
else
  log "Writing initial partition table (boot ${INITIAL_BOOT_MB}MB, root rest)..."
fi
cat > /tmp/layout.sfdisk <<EOF
label: dos
unit: sectors

${LOOP}p1 : start=${BOOT_START}, size=${BOOT_SIZE_SECTORS}, type=c, bootable
${LOOP}p2 : start=${ROOT_START}, size=${ROOT_SIZE_SECTORS}, type=83
EOF

sfdisk "$LOOP" < /tmp/layout.sfdisk >/dev/null
sync
losetup -d "$LOOP"
LOOP=$(losetup -f --show -P "$IMAGE_FILE")
log "Loop device reattached: $LOOP"
log "Creating kpartx mappings for partitions..."
kpartx -av "$LOOP" >/dev/null || true
sleep 1
BOOT_PART="/dev/mapper/$(basename "$LOOP")p1"
ROOT_PART="/dev/mapper/$(basename "$LOOP")p2"
if [[ ! -b "$BOOT_PART" || ! -b "$ROOT_PART" ]]; then
  log "Partition mapper devices not found; listing /dev/mapper:"; ls -l /dev/mapper || true
  exit 1
fi

log "Formatting boot (FAT32) and root (ext4)..."
mkfs.vfat -F32 "$BOOT_PART" >/dev/null
mkfs.ext4 -F "$ROOT_PART" >/dev/null 2>&1

log "Populating boot partition with sample files..."
mkdir -p /mnt/boot
mount "$BOOT_PART" /mnt/boot
mkdir -p /mnt/boot/overlays
echo "console=serial0,115200 console=tty1 root=PARTUUID=12345678-02 rootfstype=ext4 rootwait" > /mnt/boot/cmdline.txt
echo "# Test config.txt" > /mnt/boot/config.txt
echo "dtparam=audio=on" >> /mnt/boot/config.txt
dd if=/dev/urandom of=/mnt/boot/kernel.img bs=1M count=5 status=none
dd if=/dev/urandom of=/mnt/boot/overlays/test.dtbo bs=1K count=10 status=none
sync

if [[ "$SNAPSHOT" == "1" ]]; then
  log "Recording pre-resize boot snapshot (sha256 list)"
  find /mnt/boot -type f -exec sha256sum {} + | sed 's#/mnt/boot/##' | sort > /work/snapshot-boot-pre.txt
fi

umount /mnt/boot

log "Populating root filesystem with sample data..."
mkdir -p /mnt/root
mount "$ROOT_PART" /mnt/root
mkdir -p /mnt/root/var/log /mnt/root/usr/lib
# Create ~150MB of data (adjust as needed)
for i in $(seq 1 15); do
  dd if=/dev/urandom of=/mnt/root/var/log/log.$i bs=10M count=1 status=none
done
sync

# Optional: write pre-resize snapshot of file contents
if [[ "$SNAPSHOT" == "1" ]]; then
  log "Recording pre-resize file snapshot (sha256 list)"
  find /mnt/root -type f -exec sha256sum {} + | sed 's#/mnt/root/##' | sort > /work/snapshot-pre.txt
fi

umount /mnt/root

log "Initial layout:"; fdisk -l "$LOOP" | grep -E "^Disk|^Device" || true

log "Syncing before resize run..."
sync

log "Listing test image before resize:"; ls -l /work/"$IMAGE_FILE" || { log "Missing test image"; exit 1; }
log "Keeping loop attached to avoid race conditions"
sync; sleep 1

# Setup environment variables for resize-worker
export IMAGE_FILE="$IMAGE_FILE"
export BOOT_SIZE_MB="$EXPORT_BOOT_TARGET_MB"
export VERBOSE="$VERBOSE"

# If TARGET_IMAGE_MB is set, pass IMAGE_SIZE parameter
if [[ -n "$TARGET_IMAGE_MB" ]]; then
  export IMAGE_SIZE="${TARGET_IMAGE_MB}MB"
  log "Running resize-worker.sh: image ${INITIAL_IMAGE_MB}MB→${TARGET_IMAGE_MB}MB, boot ${INITIAL_BOOT_MB}MB→${EXPORT_BOOT_TARGET_MB}MB"
else
  log "Running resize-worker.sh: boot ${INITIAL_BOOT_MB}MB→${EXPORT_BOOT_TARGET_MB}MB (no image resize)"
fi

/usr/local/bin/resize-worker.sh || { log "Resize script failed"; exit 1; }

log "Re-attaching image for post-resize snapshot..."
POST_LOOP=$(losetup -f --show -P "$IMAGE_FILE")
log "Post loop device: $POST_LOOP"
log "Creating kpartx mappings for post snapshot..."
kpartx -av "$POST_LOOP" >/dev/null || true
sleep 1
POST_ROOT="/dev/mapper/$(basename "$POST_LOOP")p2"
POST_BOOT="/dev/mapper/$(basename "$POST_LOOP")p1"
fdisk -l "$POST_LOOP" | grep -E "^Disk|^Device" || true
blkid "$POST_BOOT" "$POST_ROOT" || true

if [[ "$SNAPSHOT" == "1" ]]; then
  if [[ -b "$POST_ROOT" ]]; then
    log "Recording post-resize root snapshot (sha256 list)"
    mkdir -p /mnt/root
    mount "$POST_ROOT" /mnt/root
    find /mnt/root -type f -exec sha256sum {} + | sed 's#/mnt/root/##' | sort > /work/snapshot-post.txt
    umount /mnt/root
  else
    log "Post root device not found; skipping post snapshot"
  fi
  
  if [[ -b "$POST_BOOT" ]]; then
    log "Recording post-resize boot snapshot (sha256 list)"
    mkdir -p /mnt/boot
    mount "$POST_BOOT" /mnt/boot
    find /mnt/boot -type f -exec sha256sum {} + | sed 's#/mnt/boot/##' | sort > /work/snapshot-boot-post.txt
    umount /mnt/boot
  else
    log "Post boot device not found; skipping boot post snapshot"
  fi
fi

log "Cleaning post snapshot loop/mappings..."
kpartx -d "$POST_LOOP" >/dev/null || true
losetup -d "$POST_LOOP" || true

log "All done."