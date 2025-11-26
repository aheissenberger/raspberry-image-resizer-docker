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
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

show_usage() {
    cat << EOF
Usage: $0 <output-image-path>

Clone a Raspberry Pi SD card to an image file.

Arguments:
  <output-image-path>      Path where the cloned image will be saved (required)

Options:
  -h, --help              Show this help message

Examples:
  $0 raspios-backup.img
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

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
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
    
    # Check each partition mounted from this device
    for part in /Volumes/*; do
        if [[ -d "$part" ]]; then
            # Check if this volume belongs to our device
            local vol_dev=$(diskutil info "$part" 2>/dev/null | grep "Device Node" | awk '{print $3}')
            if [[ "$vol_dev" == ${device}s* ]] || [[ "$vol_dev" == "$device" ]]; then
                
                # Primary indicators (weighted higher)
                if [[ -f "$part/cmdline.txt" ]]; then
                    ((score += 2))
                    indicators="${indicators}cmdline.txt "
                fi
                
                if [[ -f "$part/config.txt" ]]; then
                    ((score += 2))
                    indicators="${indicators}config.txt "
                fi
                
                if [[ -f "$part/start.elf" ]] || [[ -f "$part/start4.elf" ]]; then
                    ((score += 2))
                    indicators="${indicators}start.elf "
                fi
                
                if [[ -d "$part/overlays" ]]; then
                    ((score += 2))
                    indicators="${indicators}overlays/ "
                fi
                
                # Secondary indicators (weighted lower)
                if [[ -f "$part/bootcode.bin" ]]; then
                    ((score += 1))
                    indicators="${indicators}bootcode.bin "
                fi
                
                if ls "$part"/kernel*.img &>/dev/null; then
                    ((score += 1))
                    indicators="${indicators}kernel.img "
                fi
                
                if ls "$part"/bcm27*.dtb &>/dev/null; then
                    ((score += 1))
                    indicators="${indicators}dtb-files "
                fi
            fi
        fi
    done
    
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

# Get list of all disks
for disk in $(diskutil list | grep "^/dev/disk" | awk '{print $1}'); do
    # Extract disk number
    disk_id=$(basename "$disk")
    
    # Skip internal disks (disk0 is typically internal)
    disk_info=$(diskutil info "$disk" 2>/dev/null)
    
    # Check if it's removable/external
    is_removable=$(echo "$disk_info" | grep -E "Removable Media:|Protocol:" | grep -q "Yes\|USB\|SD" && echo "yes" || echo "no")
    
    if [[ "$is_removable" == "yes" ]] && echo "$disk_info" | grep -q "Protocol.*USB\|Protocol.*SD"; then
        # Check for Raspberry Pi indicators (multi-factor detection)
        detection_result=$(check_raspberry_pi_indicators "$disk")
        detection_score=$(echo "$detection_result" | cut -d: -f1)
        detection_indicators=$(echo "$detection_result" | cut -d: -f2-)
        
        # Only include devices with sufficient confidence (score >= 4)
        if [[ $detection_score -ge 4 ]]; then
            # Get device name/label
            device_name=$(echo "$disk_info" | grep "Device / Media Name" | awk -F": " '{print $2}' | xargs)
            if [[ -z "$device_name" ]]; then
                device_name="Unknown"
            fi
            
            # Get size
            device_size=$(echo "$disk_info" | grep "Disk Size" | awk -F"(" '{print $2}' | awk '{print $1}')
            device_size_human=$(human_size "$device_size")
            
            # Store device info
            DEVICES[$INDEX]="$disk"
            DEVICE_NAMES[$INDEX]="$device_name"
            DEVICE_SIZES[$INDEX]="$device_size_human"
            DEVICE_PATHS[$INDEX]="$disk"
            DEVICE_INDICATORS[$INDEX]="$detection_indicators"
            
            INDEX=$((INDEX + 1))
        fi
    fi
done

# Check if any devices were found
if [[ $INDEX -eq 0 ]]; then
    log_error "No Raspberry Pi SD cards detected."
    log_info "Please ensure:"
    log_info "  - The SD card is properly inserted"
    log_info "  - The SD card is mounted"
    log_info "  - The SD card contains a Raspberry Pi OS"
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
if ! echo "$SELECTED_DEVICE_INFO" | grep -q "Protocol.*USB\|Protocol.*SD"; then
    log_error "Selected device is not an external/removable device"
    log_error "For safety, only USB and SD card devices can be cloned"
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
log_info "Press Ctrl+T to see progress during cloning"
log_info "Starting 'dd' operation (requires sudo)..."
echo ""

# Check if pv (pipe viewer) is available for progress bar
if command -v pv &> /dev/null; then
    # Use pv to show progress bar
    log_info "Using progress bar (pv detected)"
    if ! sudo dd if="$RAW_DEVICE" bs=4m 2>/dev/null | pv -s "$DEVICE_SIZE_BYTES" | dd of="$OUTPUT_IMAGE" bs=4m 2>/dev/null; then
        log_error "Clone operation failed"
        rm -f "$OUTPUT_IMAGE" 2>/dev/null
        exit 1
    fi
else
    # Fallback to standard dd (use Ctrl+T for progress on macOS)
    log_info "Note: Install 'pv' (brew install pv) for a progress bar"
    if ! sudo dd if="$RAW_DEVICE" of="$OUTPUT_IMAGE" bs=4m status=progress 2>&1; then
        log_error "Clone operation failed"
        rm -f "$OUTPUT_IMAGE" 2>/dev/null
        exit 1
    fi
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
