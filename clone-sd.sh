#!/bin/bash

# Raspberry Pi SD Card Cloner
# Clones a Raspberry Pi SD card to an image file on macOS

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
    if [[ $VERBOSE -eq 1 ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1" >&2
    fi
}

show_usage() {
    cat << EOF
Usage: $0 <output-image-path>

Clone a Raspberry Pi SD card to an image file.

Arguments:
  <output-image-path>      Path where the cloned image will be saved (required)

Options:
  -h, --help              Show this help message
  -v, --verbose           Show detailed debug output

Examples:
  $0 raspios-backup.img
  $0 raspios-backup.img --verbose
  $0 ~/Images/my-raspberrypi.img

Notes:
  - This script will scan all mounted external devices for Raspberry Pi SD cards
  - Uses multi-factor detection (cmdline.txt, config.txt, start.elf, overlays/)
  - Requires at least 2 Raspberry Pi indicators to identify a valid SD card
  - You will be prompted to select which device to clone
  - The cloning process can take several minutes to hours depending on SD card size

EOF
    exit 0
}

# Parse arguments
OUTPUT_IMAGE=""
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        *)
            if [[ -z "$OUTPUT_IMAGE" ]]; then
                OUTPUT_IMAGE="$1"
            else
                log_error "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "$OUTPUT_IMAGE" ]]; then
    log_error "Missing required argument: <output-image-path>"
    echo ""
    show_usage
fi

# Convert to absolute path
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT_IMAGE")" 2>/dev/null && pwd)" || OUTPUT_DIR="$(pwd)"
OUTPUT_NAME="$(basename "$OUTPUT_IMAGE")"
OUTPUT_IMAGE="$OUTPUT_DIR/$OUTPUT_NAME"

# Check if output file already exists and request confirmation
if [[ -f "$OUTPUT_IMAGE" ]]; then
    log_warn "Output file already exists: $OUTPUT_IMAGE"
    read -p "Do you want to overwrite it? (yes/no): " OVERWRITE_CONFIRM
    
    if [[ "$OVERWRITE_CONFIRM" != "yes" ]]; then
        log_info "Operation cancelled. Please choose a different filename."
        exit 0
    fi
    
    log_warn "Existing file will be overwritten"
fi

log_info "Raspberry Pi SD Card Cloner"
log_info "==========================="
log_info "Output image: $OUTPUT_IMAGE"
echo ""

# Function to get human-readable size
human_size() {
    local bytes=$1
    local gb=$((bytes / 1024 / 1024 / 1024))
    local mb=$((bytes / 1024 / 1024))
    
    if [[ $gb -gt 0 ]]; then
        echo "${gb} GB"
    else
        echo "${mb} MB"
    fi
}

# Function to check if device is a Raspberry Pi SD card using multi-factor detection
# Returns: score (0-7) indicating confidence level
check_raspberry_pi_indicators() {
    local device=$1
    local score=0
    local indicators=""
    
    log_debug "    Checking Raspberry Pi indicators on $device partitions"
    
    # Get list of partitions for this device and their mount points
    while IFS= read -r part_line; do
        # Extract partition device (e.g., disk16s1)
        local part_device=$(echo "$part_line" | awk '{print $NF}')
        
        # Skip if this is the disk itself, not a partition
        if [[ "$part_device" == "$device" ]] || [[ ! "$part_device" =~ s[0-9]+$ ]]; then
            continue
        fi
        
        log_debug "      Checking partition: $part_device"
        
        # Get mount point for this partition
        local mount_point=$(diskutil info "/dev/$part_device" 2>/dev/null | grep "Mount Point:" | sed 's/.*Mount Point:[[:space:]]*//')
        
        if [[ -n "$mount_point" ]] && [[ -d "$mount_point" ]]; then
            log_debug "        Mount point: $mount_point"
            
            # Primary indicators (weighted higher)
            if [[ -f "$mount_point/cmdline.txt" ]]; then
                ((score += 2))
                indicators="${indicators}cmdline.txt "
                log_debug "        ✓ Found cmdline.txt"
            fi
            
            if [[ -f "$mount_point/config.txt" ]]; then
                ((score += 2))
                indicators="${indicators}config.txt "
                log_debug "        ✓ Found config.txt"
            fi
            
            if [[ -f "$mount_point/start.elf" ]] || [[ -f "$mount_point/start4.elf" ]]; then
                ((score += 2))
                indicators="${indicators}start.elf "
                log_debug "        ✓ Found start.elf"
            fi
            
            if [[ -d "$mount_point/overlays" ]]; then
                ((score += 2))
                indicators="${indicators}overlays/ "
                log_debug "        ✓ Found overlays/"
            fi
            
            # Secondary indicators (weighted lower)
            if [[ -f "$mount_point/bootcode.bin" ]]; then
                ((score += 1))
                indicators="${indicators}bootcode.bin "
                log_debug "        ✓ Found bootcode.bin"
            fi
            
            if ls "$mount_point"/kernel*.img &>/dev/null; then
                ((score += 1))
                indicators="${indicators}kernel.img "
                log_debug "        ✓ Found kernel*.img"
            fi
            
            if ls "$mount_point"/bcm27*.dtb &>/dev/null; then
                ((score += 1))
                indicators="${indicators}dtb-files "
                log_debug "        ✓ Found bcm27*.dtb"
            fi
        else
            log_debug "        Not mounted"
        fi
    done < <(diskutil list "$device" | grep -E '^\s+[0-9]+:')
    
    log_debug "    Final score: $score, Indicators: $indicators"
    
    # Export score and indicators for caller
    echo "$score:$indicators"
    
    # Return success if score >= 4 (at least 2 primary indicators)
    [[ $score -ge 4 ]]
}

# Scan for external devices
log_info "Scanning for external devices with Raspberry Pi SD cards..."
echo ""

declare -a DEVICES
declare -a DEVICE_NAMES
declare -a DEVICE_SIZES
declare -a DEVICE_PATHS
declare -a DEVICE_INDICATORS

INDEX=0

# Get list of all disks using process substitution to preserve array values
while IFS= read -r disk_line; do
    # Extract disk device from lines like "/dev/disk16 (internal, physical):"
    disk=$(echo "$disk_line" | grep -oE '/dev/disk[0-9]+' | head -1)
    
    if [[ -z "$disk" ]]; then
        continue
    fi
    
    log_debug "Checking disk: $disk"
    
    # Get disk info
    disk_info=$(diskutil info "$disk" 2>/dev/null)
    
    if [[ -z "$disk_info" ]]; then
        log_debug "  No disk info available"
        continue
    fi
    
    # Check if it's internal (skip internal disks, but allow SD cards)
    is_internal=$(echo "$disk_info" | grep "Device Location:" | grep -q "Internal" && echo "yes" || echo "no")
    is_removable=$(echo "$disk_info" | grep "Removable Media:" | grep -q "Removable" && echo "yes" || echo "no")
    protocol=$(echo "$disk_info" | grep "Protocol:" | awk -F": " '{print $2}' | xargs)
    
    log_debug "  Internal: $is_internal, Removable: $is_removable, Protocol: $protocol"
    
    # Skip internal non-removable disks (likely system disks)
    if [[ "$is_internal" == "yes" ]] && [[ "$is_removable" != "yes" ]]; then
        log_debug "  Skipping internal non-removable disk"
        continue
    fi
    
    # Get disk size
    device_size=$(echo "$disk_info" | grep "Disk Size" | awk -F"(" '{print $2}' | awk '{print $1}')
    device_size_gb=$((device_size / 1024 / 1024 / 1024))
    
    log_debug "  Size: ${device_size_gb} GB"
    
    # Skip disks > 2TB (unlikely to be SD cards)
    if [[ $device_size_gb -gt 2048 ]]; then
        log_debug "  Skipping: size > 2TB"
        continue
    fi
    
    # Check for boot partition (Windows_FAT_32 named "boot")
    has_boot_partition=false
    while IFS= read -r partition_line; do
        # Extract fields from diskutil list output: "   1:             Windows_FAT_32 boot                    66.1 MB    disk16s1"
        part_type=$(echo "$partition_line" | awk '{print $2}')
        part_name=$(echo "$partition_line" | awk '{print $3}')
        part_device=$(echo "$partition_line" | awk '{print $NF}')
        
        log_debug "    Partition: $part_device, Type: $part_type, Name: $part_name"
        
        if [[ "$part_type" == "Windows_FAT_32" ]] && [[ "$part_name" == "boot" ]]; then
            has_boot_partition=true
            log_debug "    Found boot partition!"
            break
        fi
    done < <(diskutil list "$disk" | grep -E '^\s+[0-9]+:')
    
    if [[ "$has_boot_partition" == "false" ]]; then
        log_debug "  Skipping: no Windows_FAT_32 'boot' partition found"
        continue
    fi
    
    # Allow internal SD card readers - check for SD protocol or Secure Digital in device name
    device_name=$(echo "$disk_info" | grep "Device / Media Name" | awk -F": " '{print $2}' | xargs)
    is_sd_card=false
    if [[ "$protocol" == "Secure Digital" ]] || [[ "$protocol" == "SD" ]] || [[ "$device_name" == *"SDXC"* ]] || [[ "$device_name" == *"SD Card"* ]]; then
        is_sd_card=true
        log_debug "  Detected as SD card"
    fi
    
    # Check if it's USB, SD card, or removable
    if [[ "$is_removable" == "yes" ]] || [[ "$protocol" =~ USB|SD ]] || [[ "$is_sd_card" == "true" ]]; then
        log_debug "  Checking for Raspberry Pi indicators..."
        
        # Check for Raspberry Pi indicators (multi-factor detection)
        detection_result=$(check_raspberry_pi_indicators "$disk")
        detection_score=$(echo "$detection_result" | cut -d: -f1)
        detection_indicators=$(echo "$detection_result" | cut -d: -f2-)
        
        log_debug "  Detection score: $detection_score, Indicators: $detection_indicators"
        
        # Only include devices with sufficient confidence (score >= 4)
        if [[ $detection_score -ge 4 ]]; then
            if [[ -z "$device_name" ]]; then
                device_name="Unknown"
            fi
            
            # Get size
            device_size=$(echo "$disk_info" | grep "Disk Size" | awk -F"(" '{print $2}' | awk '{print $1}')
            device_size_human=$(human_size "$device_size")
            
            log_debug "  ✓ Added to device list"
            
            # Store device info
            DEVICES[$INDEX]="$disk"
            DEVICE_NAMES[$INDEX]="$device_name"
            DEVICE_SIZES[$INDEX]="$device_size_human"
            DEVICE_PATHS[$INDEX]="$disk"
            DEVICE_INDICATORS[$INDEX]="$detection_indicators"
            
            INDEX=$((INDEX + 1))
        else
            log_debug "  Score too low ($detection_score), not a Raspberry Pi SD card"
        fi
    else
        log_debug "  Not removable/USB/SD, skipping"
    fi
done < <(diskutil list | grep -E '^/dev/disk[0-9]+')

echo ""

# Check if any devices were found
if [[ $INDEX -eq 0 ]]; then
    log_error "No Raspberry Pi SD cards detected."
    log_info ""
    log_info "Troubleshooting:"
    log_info "  1. Ensure the SD card is properly inserted"
    log_info "  2. Check if partitions are mounted:"
    log_info "     Run: diskutil list"
    log_info "     Look for mounted volumes under your SD card"
    log_info "  3. Mount the boot partition manually:"
    log_info "     Run: diskutil mount /dev/diskXs1  (replace X with your disk number)"
    log_info "  4. Check /Volumes/ for mounted partitions:"
    log_info "     Run: ls -la /Volumes/"
    log_info ""
    log_info "Detection requires at least 2 of these indicators:"
    log_info "  - cmdline.txt (kernel command line)"
    log_info "  - config.txt (firmware configuration)"
    log_info "  - start.elf or start4.elf (GPU firmware)"
    log_info "  - overlays/ directory (device tree overlays)"
    exit 1
fi

# Display detected devices
log_info "Detected Raspberry Pi SD cards:"
echo ""
printf "%5s  %-15s  %-30s  %-10s  %s\n" "Index" "Device" "Name" "Size" "Indicators"
printf "%5s  %-15s  %-30s  %-10s  %s\n" "-----" "---------------" "------------------------------" "----------" "------------------------"

for i in "${!DEVICES[@]}"; do
    # Truncate indicators if too long
    indicators_short=$(echo "${DEVICE_INDICATORS[$i]}" | cut -c1-50)
    printf "%5s  %-15s  %-30s  %-10s  %s\n" "[$i]" "${DEVICE_PATHS[$i]}" "${DEVICE_NAMES[$i]}" "${DEVICE_SIZES[$i]}" "$indicators_short"
done

echo ""

# Prompt for selection
while true; do
    read -p "Enter the index number of the device to clone [0-$((INDEX-1))]: " SELECTION
    
    # Validate input
    if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [[ $SELECTION -ge 0 ]] && [[ $SELECTION -lt $INDEX ]]; then
        break
    else
        log_error "Invalid selection. Please enter a number between 0 and $((INDEX-1))."
    fi
done

# Get selected device info
SELECTED_DEVICE="${DEVICES[$SELECTION]}"
SELECTED_NAME="${DEVICE_NAMES[$SELECTION]}"
SELECTED_SIZE="${DEVICE_SIZES[$SELECTION]}"
SELECTED_INDICATORS="${DEVICE_INDICATORS[$SELECTION]}"

echo ""
log_info "Selected device:"
log_info "  Device: $SELECTED_DEVICE"
log_info "  Name: $SELECTED_NAME"
log_info "  Size: $SELECTED_SIZE"
log_info "  Detected files: $SELECTED_INDICATORS"
log_info "  Output: $OUTPUT_IMAGE"
echo ""

# Verify the selected device is removable/external
SELECTED_DEVICE_INFO=$(diskutil info "$SELECTED_DEVICE")
selected_protocol=$(echo "$SELECTED_DEVICE_INFO" | grep "Protocol:" | awk -F": " '{print $2}' | xargs)
selected_removable=$(echo "$SELECTED_DEVICE_INFO" | grep "Removable Media:" | grep -q "Removable" && echo "yes" || echo "no")

# Allow USB, SD protocols, or any Secure Digital device, or removable devices
if [[ "$selected_protocol" != "USB" ]] && [[ "$selected_protocol" != "Secure Digital" ]] && [[ "$selected_protocol" != "SD" ]] && [[ "$selected_removable" != "yes" ]]; then
    log_error "Selected device is not an external/removable device"
    log_error "For safety, only USB, SD card, and removable devices can be cloned"
    log_error "Device protocol: $selected_protocol, Removable: $selected_removable"
    exit 1
fi

# Get raw device path (rdisk instead of disk for faster operation)
RAW_DEVICE=$(echo "$SELECTED_DEVICE" | sed 's|/dev/disk|/dev/rdisk|')

# Check available disk space
DEVICE_SIZE_BYTES=$(diskutil info "$SELECTED_DEVICE" | grep "Disk Size" | awk -F"(" '{print $2}' | awk '{print $1}')
AVAILABLE_SPACE=$(df "$OUTPUT_DIR" | tail -1 | awk '{print $4}')
AVAILABLE_SPACE_BYTES=$((AVAILABLE_SPACE * 1024))

if [[ $AVAILABLE_SPACE_BYTES -lt $DEVICE_SIZE_BYTES ]]; then
    log_error "Insufficient disk space in $OUTPUT_DIR"
    log_error "Required: $(human_size $DEVICE_SIZE_BYTES)"
    log_error "Available: $(human_size $AVAILABLE_SPACE_BYTES)"
    exit 1
fi

# Estimate time based on size
ESTIMATED_MINUTES=$((DEVICE_SIZE_BYTES / 1024 / 1024 / 20))  # Rough estimate: 20 MB/s
if [[ $ESTIMATED_MINUTES -lt 1 ]]; then
    ESTIMATED_MINUTES=1
fi
ESTIMATED_TIME="approximately $ESTIMATED_MINUTES minutes"
if [[ $ESTIMATED_MINUTES -gt 60 ]]; then
    ESTIMATED_HOURS=$((ESTIMATED_MINUTES / 60))
    ESTIMATED_TIME="approximately $ESTIMATED_HOURS hour(s)"
fi

# Final confirmation with time warning
log_warn "==================== IMPORTANT WARNING ===================="
log_warn "This will clone the ENTIRE SD card to an image file."
log_warn "Device: $SELECTED_DEVICE ($SELECTED_NAME)"
log_warn "Size: $SELECTED_SIZE"
log_warn "Estimated time: $ESTIMATED_TIME"
log_warn "=========================================================="
echo ""
read -p "Are you sure you want to proceed? (yes/no): " CONFIRM

if [[ "$CONFIRM" != "yes" ]]; then
    log_info "Operation cancelled by user."
    exit 0
fi

# Double confirmation before dd operation
echo ""
log_warn "FINAL CONFIRMATION: About to execute 'dd' command."
read -p "Type 'CLONE' to confirm and start cloning: " FINAL_CONFIRM

if [[ "$FINAL_CONFIRM" != "CLONE" ]]; then
    log_info "Operation cancelled. Clone command not confirmed."
    exit 0
fi

echo ""
log_info "Starting clone operation..."
log_info "This may take several minutes to hours. Please be patient."
echo ""

# Unmount the device (but don't eject)
log_info "Unmounting volumes on $SELECTED_DEVICE..."
diskutil unmountDisk "$SELECTED_DEVICE" > /dev/null 2>&1 || true

# Perform the clone using dd with progress
log_info "Cloning $RAW_DEVICE to $OUTPUT_IMAGE..."
log_info "Press Ctrl+T to see progress during cloning (macOS feature)"
log_info "Starting 'dd' operation (requires sudo)..."
log_info "Using optimized block size: 16MB for maximum throughput"
echo ""

# Use 16MB block size for optimal throughput on macOS
# rdisk (raw disk) bypasses system buffering for faster I/O
if ! sudo dd if="$RAW_DEVICE" of="$OUTPUT_IMAGE" bs=16m status=progress 2>&1; then
    log_error "Clone operation failed"
    rm -f "$OUTPUT_IMAGE" 2>/dev/null
    exit 1
fi

# Sync to ensure all data is written
sync

echo ""
log_info "Clone completed successfully!"

# Verify the output image was created successfully
if [[ ! -f "$OUTPUT_IMAGE" ]]; then
    log_error "Output image file not found: $OUTPUT_IMAGE"
    log_error "Clone may have failed"
    exit 1
fi

# Verify file size matches expected size
ACTUAL_SIZE=$(stat -f%z "$OUTPUT_IMAGE" 2>/dev/null || echo "0")
if [[ $ACTUAL_SIZE -eq 0 ]]; then
    log_error "Output image file is empty or unreadable"
    exit 1
fi

# Check if size is reasonable (should be close to device size)
SIZE_DIFF=$((DEVICE_SIZE_BYTES - ACTUAL_SIZE))
SIZE_DIFF=${SIZE_DIFF#-}  # Absolute value
SIZE_DIFF_PERCENT=$((SIZE_DIFF * 100 / DEVICE_SIZE_BYTES))

if [[ $SIZE_DIFF_PERCENT -gt 10 ]]; then
    log_warn "Output image size differs significantly from device size"
    log_warn "Expected: $(human_size $DEVICE_SIZE_BYTES), Got: $(human_size $ACTUAL_SIZE)"
    log_warn "The image may be incomplete"
fi

log_info "Output image: $OUTPUT_IMAGE"

# Get final file size
FINAL_SIZE=$(ls -lh "$OUTPUT_IMAGE" | awk '{print $5}')
log_info "Image size: $FINAL_SIZE"

# Verify image has valid partition table
log_info "Verifying image integrity..."
if file "$OUTPUT_IMAGE" | grep -q "DOS/MBR boot sector"; then
    log_info "✓ Image has valid boot sector"
else
    log_warn "⚠ Image boot sector verification inconclusive"
fi

echo ""
log_info "You can now use resize-image.sh to modify this image if needed:"
log_info "  ./resize-image.sh $OUTPUT_IMAGE --boot-size 512"

exit 0
