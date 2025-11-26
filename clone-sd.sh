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

# Function to scan for Raspberry Pi SD card devices
# Populates global arrays: DEVICES, DEVICE_NAMES, DEVICE_SIZES, DEVICE_PATHS, DEVICE_INDICATORS
# Returns: number of devices found
scan_for_raspberry_pi_devices() {
    index=0
    
    log_debug "Starting device scan..."
    
    # Get list of all disks using process substitution to preserve array values
    while IFS= read -r disk_line; do
        # Extract disk device from lines like "/dev/disk16 (internal, physical):"
        local disk=$(echo "$disk_line" | grep -oE '/dev/disk[0-9]+' | head -1)
        
        if [[ -z "$disk" ]]; then
            continue
        fi
        
        log_debug "Checking disk: $disk"
        
        # Get disk info
        local disk_info=$(diskutil info "$disk" 2>/dev/null)
        
        if [[ -z "$disk_info" ]]; then
            log_debug "  No disk info available"
            continue
        fi
        
        # Check if it's internal (skip internal disks, but allow SD cards)
        local is_internal=$(echo "$disk_info" | grep "Device Location:" | grep -q "Internal" && echo "yes" || echo "no")
        local is_removable=$(echo "$disk_info" | grep "Removable Media:" | grep -q "Removable" && echo "yes" || echo "no")
        local protocol=$(echo "$disk_info" | grep "Protocol:" | awk -F": " '{print $2}' | xargs)
        
        log_debug "  Internal: $is_internal, Removable: $is_removable, Protocol: $protocol"
        
        # Skip internal non-removable disks (likely system disks)
        if [[ "$is_internal" == "yes" ]] && [[ "$is_removable" != "yes" ]]; then
            log_debug "  Skipping internal non-removable disk"
            continue
        fi
        
        # Get disk size
        local device_size=$(echo "$disk_info" | grep "Disk Size" | awk -F"(" '{print $2}' | awk '{print $1}')
        local device_size_gb=$((device_size / 1024 / 1024 / 1024))
        
        log_debug "  Size: ${device_size_gb} GB"
        
        # Skip disks > 2TB (unlikely to be SD cards)
        if [[ $device_size_gb -gt 2048 ]]; then
            log_debug "  Skipping: size > 2TB"
            continue
        fi
        
        # Check for boot partition (Windows_FAT_32 named "boot")
        local has_boot_partition=false
        while IFS= read -r partition_line; do
            # Extract fields from diskutil list output: "   1:             Windows_FAT_32 boot                    66.1 MB    disk16s1"
            local part_type=$(echo "$partition_line" | awk '{print $2}')
            local part_name=$(echo "$partition_line" | awk '{print $3}')
            local part_device=$(echo "$partition_line" | awk '{print $NF}')
            
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
        local device_name=$(echo "$disk_info" | grep "Device / Media Name" | awk -F": " '{print $2}' | xargs)
        local is_sd_card=false
        if [[ "$protocol" == "Secure Digital" ]] || [[ "$protocol" == "SD" ]] || [[ "$device_name" == *"SDXC"* ]] || [[ "$device_name" == *"SD Card"* ]]; then
            is_sd_card=true
            log_debug "  Detected as SD card"
        fi
        
        # Check if it's USB, SD card, or removable
        if [[ "$is_removable" == "yes" ]] || [[ "$protocol" =~ USB|SD ]] || [[ "$is_sd_card" == "true" ]]; then
            log_debug "  Checking for Raspberry Pi indicators..."
            
            # Check for Raspberry Pi indicators (multi-factor detection)
            local detection_result=$(check_raspberry_pi_indicators "$disk")
            local detection_score=$(echo "$detection_result" | cut -d: -f1)
            local detection_indicators=$(echo "$detection_result" | cut -d: -f2-)
            
            log_debug "  Detection score: $detection_score, Indicators: $detection_indicators"
            
            # Only include devices with sufficient confidence (score >= 4)
            if [[ $detection_score -ge 4 ]]; then
                if [[ -z "$device_name" ]]; then
                    device_name="Unknown"
                fi
                
                # Get size
                device_size=$(echo "$disk_info" | grep "Disk Size" | awk -F"(" '{print $2}' | awk '{print $1}')
                local device_size_human=$(human_size "$device_size")
                
                log_debug "  ✓ Added to device list"
                
                # Store device info
                DEVICES[$index]="$disk"
                DEVICE_NAMES[$index]="$device_name"
                DEVICE_SIZES[$index]="$device_size_human"
                DEVICE_PATHS[$index]="$disk"
                DEVICE_INDICATORS[$index]="$detection_indicators"
                
                index=$((index + 1))
            else
                log_debug "  Score too low ($detection_score), not a Raspberry Pi SD card"
            fi
        else
            log_debug "  Not removable/USB/SD, skipping"
        fi
    done < <(diskutil list | grep -E '^/dev/disk[0-9]+')
    
    log_debug "Device scan complete. Found $index device(s)"
    
    return $index
}

# Scan for external devices
log_info "Scanning for external devices with Raspberry Pi SD cards..."
echo ""

# Initialize arrays at script level (global scope)
DEVICES=()
DEVICE_NAMES=()
DEVICE_SIZES=()
DEVICE_PATHS=()
DEVICE_INDICATORS=()

scan_for_raspberry_pi_devices || true
INDEX=$index

log_debug "Scan returned: INDEX=$INDEX devices"
log_debug "DEVICES array length: ${#DEVICES[@]}"

if [[ ${#DEVICES[@]} -gt 0 ]]; then
    log_debug "First device: ${DEVICES[0]}"
    log_debug "First device name: ${DEVICE_NAMES[0]}"
else
    log_debug "Arrays are EMPTY after function call!"
fi

echo ""

# Function to show error if no devices found
show_no_devices_error() {
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
}

# Function to display detected devices in a table
display_detected_devices() {
    local device_count=$1
    
    log_info "Detected Raspberry Pi SD cards:"
    echo ""
    printf "%5s  %-15s  %-30s  %-10s  %s\n" "Index" "Device" "Name" "Size" "Indicators"
    printf "%5s  %-15s  %-30s  %-10s  %s\n" "-----" "---------------" "------------------------------" "----------" "------------------------"
    
    for i in "${!DEVICES[@]}"; do
        # Truncate indicators if too long
        local indicators_short=$(echo "${DEVICE_INDICATORS[$i]}" | cut -c1-50)
        printf "%5s  %-15s  %-30s  %-10s  %s\n" "[$i]" "${DEVICE_PATHS[$i]}" "${DEVICE_NAMES[$i]}" "${DEVICE_SIZES[$i]}" "$indicators_short"
    done
    
    echo ""
}

# Function to prompt user to select a device
# Returns: selected index
select_device() {
    local max_index=$(($1 - 1))
    local selection
    
    while true; do
        read -p "Enter the index number of the device to clone [0-${max_index}]: " selection
        
        # Validate input
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ $selection -ge 0 ]] && [[ $selection -le $max_index ]]; then
            echo "$selection"
            return 0
        else
            log_error "Invalid selection. Please enter a number between 0 and ${max_index}."
        fi
    done
}

# Function to get and display selected device info
# Sets global variables: SELECTED_DEVICE, SELECTED_NAME, SELECTED_SIZE, SELECTED_INDICATORS
get_selected_device_info() {
    local selection=$1
    
    SELECTED_DEVICE="${DEVICES[$selection]}"
    SELECTED_NAME="${DEVICE_NAMES[$selection]}"
    SELECTED_SIZE="${DEVICE_SIZES[$selection]}"
    SELECTED_INDICATORS="${DEVICE_INDICATORS[$selection]}"
    
    echo ""
    log_info "Selected device:"
    log_info "  Device: $SELECTED_DEVICE"
    log_info "  Name: $SELECTED_NAME"
    log_info "  Size: $SELECTED_SIZE"
    log_info "  Detected files: $SELECTED_INDICATORS"
    log_info "  Output: $OUTPUT_IMAGE"
    echo ""
}

# Function to verify device is removable/external
# Returns: 0 if valid, 1 if not
verify_device_is_removable() {
    local device=$1
    
    local device_info=$(diskutil info "$device")
    local protocol=$(echo "$device_info" | grep "Protocol:" | awk -F": " '{print $2}' | xargs)
    local removable=$(echo "$device_info" | grep "Removable Media:" | grep -q "Removable" && echo "yes" || echo "no")
    
    # Allow USB, SD protocols, or any Secure Digital device, or removable devices
    if [[ "$protocol" != "USB" ]] && [[ "$protocol" != "Secure Digital" ]] && [[ "$protocol" != "SD" ]] && [[ "$removable" != "yes" ]]; then
        log_error "Selected device is not an external/removable device"
        log_error "For safety, only USB, SD card, and removable devices can be cloned"
        log_error "Device protocol: $protocol, Removable: $removable"
        return 1
    fi
    
    return 0
}

# Function to check available disk space
# Returns: 0 if sufficient space, 1 if not
check_disk_space() {
    local device=$1
    local output_dir=$2
    
    local device_size=$(diskutil info "$device" | grep "Disk Size" | awk -F"(" '{print $2}' | awk '{print $1}')
    local available_space=$(df "$output_dir" | tail -1 | awk '{print $4}')
    local available_bytes=$((available_space * 1024))
    
    if [[ $available_bytes -lt $device_size ]]; then
        log_error "Insufficient disk space in $output_dir"
        log_error "Required: $(human_size $device_size)"
        log_error "Available: $(human_size $available_bytes)"
        return 1
    fi
    
    # Store device size globally for later use
    DEVICE_SIZE_BYTES=$device_size
    
    return 0
}

# Function to estimate clone time
# Returns: estimated time string
estimate_clone_time() {
    local size_bytes=$1
    
    local minutes=$((size_bytes / 1024 / 1024 / 20))  # Rough estimate: 20 MB/s
    if [[ $minutes -lt 1 ]]; then
        minutes=1
    fi
    
    if [[ $minutes -gt 60 ]]; then
        local hours=$((minutes / 60))
        echo "approximately $hours hour(s)"
    else
        echo "approximately $minutes minutes"
    fi
}

# Function to get user confirmation for cloning
# Returns: 0 if confirmed, 1 if cancelled
get_user_confirmation() {
    local device=$1
    local name=$2
    local size=$3
    local estimated_time=$4
    
    log_warn "==================== IMPORTANT WARNING ===================="
    log_warn "This will clone the ENTIRE SD card to an image file."
    log_warn "Device: $device ($name)"
    log_warn "Size: $size"
    log_warn "Estimated time: $estimated_time"
    log_warn "=========================================================="
    echo ""
    read -p "Are you sure you want to proceed? (yes/no): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        log_info "Operation cancelled by user."
        return 1
    fi
    
    # Double confirmation before dd operation
    echo ""
    log_warn "FINAL CONFIRMATION: About to execute 'dd' command."
    read -p "Type 'CLONE' to confirm and start cloning: " final_confirm
    
    if [[ "$final_confirm" != "CLONE" ]]; then
        log_info "Operation cancelled. Clone command not confirmed."
        return 1
    fi
    
    return 0
}

# Function to perform the clone operation
# Returns: 0 if successful, 1 if failed
perform_clone() {
    local device=$1
    local output_image=$2
    
    # Get raw device path (rdisk instead of disk for faster operation)
    local raw_device=$(echo "$device" | sed 's|/dev/disk|/dev/rdisk|')
    
    echo ""
    log_info "Starting clone operation..."
    log_info "This may take several minutes to hours. Please be patient."
    echo ""
    
    # Unmount the device (but don't eject)
    log_info "Unmounting volumes on $device..."
    diskutil unmountDisk "$device" > /dev/null 2>&1 || true
    
    # Perform the clone using dd with progress
    log_info "Cloning $raw_device to $output_image..."
    log_info "Press Ctrl+T to see progress during cloning (macOS feature)"
    log_info "Starting 'dd' operation (requires sudo)..."
    log_info "Using optimized block size: 16MB for maximum throughput"
    echo ""
    
    # Use 16MB block size for optimal throughput on macOS
    # rdisk (raw disk) bypasses system buffering for faster I/O
    if ! sudo dd if="$raw_device" of="$output_image" bs=16m status=progress 2>&1; then
        log_error "Clone operation failed"
        rm -f "$output_image" 2>/dev/null
        return 1
    fi
    
    # Sync to ensure all data is written
    sync
    
    echo ""
    log_info "Clone completed successfully!"
    
    return 0
}

# Function to verify cloned image
# Returns: 0 if valid, 1 if issues found
verify_cloned_image() {
    local output_image=$1
    local expected_size=$2
    
    # Verify the output image was created successfully
    if [[ ! -f "$output_image" ]]; then
        log_error "Output image file not found: $output_image"
        log_error "Clone may have failed"
        return 1
    fi
    
    # Verify file size matches expected size
    local actual_size=$(stat -f%z "$output_image" 2>/dev/null || echo "0")
    if [[ $actual_size -eq 0 ]]; then
        log_error "Output image file is empty or unreadable"
        return 1
    fi
    
    # Check if size is reasonable (should be close to device size)
    local size_diff=$((expected_size - actual_size))
    size_diff=${size_diff#-}  # Absolute value
    local size_diff_percent=$((size_diff * 100 / expected_size))
    
    if [[ $size_diff_percent -gt 10 ]]; then
        log_warn "Output image size differs significantly from device size"
        log_warn "Expected: $(human_size $expected_size), Got: $(human_size $actual_size)"
        log_warn "The image may be incomplete"
    fi
    
    log_info "Output image: $output_image"
    
    # Get final file size
    local final_size=$(ls -lh "$output_image" | awk '{print $5}')
    log_info "Image size: $final_size"
    
    # Verify image has valid partition table
    log_info "Verifying image integrity..."
    if file "$output_image" | grep -q "DOS/MBR boot sector"; then
        log_info "✓ Image has valid boot sector"
    else
        log_warn "⚠ Image boot sector verification inconclusive"
    fi
    
    return 0
}

# Main workflow
if [[ $INDEX -eq 0 ]] || [[ ${#DEVICES[@]} -eq 0 ]]; then
    log_debug "No devices found, showing error..."
    show_no_devices_error
    exit 1
fi

log_debug "Proceeding to display ${#DEVICES[@]} device(s)..."

display_detected_devices ${#DEVICES[@]}

echo ""

log_debug "Prompting for device selection..."

SELECTION=$(select_device $INDEX)

log_debug "User selected: $SELECTION"

get_selected_device_info $SELECTION

log_debug "Verifying device is removable..."

if ! verify_device_is_removable "$SELECTED_DEVICE"; then
    exit 1
fi

log_debug "Checking disk space..."

if ! check_disk_space "$SELECTED_DEVICE" "$OUTPUT_DIR"; then
    exit 1
fi

ESTIMATED_TIME=$(estimate_clone_time $DEVICE_SIZE_BYTES)

log_debug "Getting user confirmation..."

if ! get_user_confirmation "$SELECTED_DEVICE" "$SELECTED_NAME" "$SELECTED_SIZE" "$ESTIMATED_TIME"; then
    exit 0
fi

log_debug "Starting clone operation..."

if ! perform_clone "$SELECTED_DEVICE" "$OUTPUT_IMAGE"; then
    exit 1
fi

log_debug "Verifying cloned image..."

if ! verify_cloned_image "$OUTPUT_IMAGE" "$DEVICE_SIZE_BYTES"; then
    exit 1
fi

echo ""
log_info "✓ Clone operation completed successfully!"
log_info ""
log_info "You can now use resize-image.sh to modify this image if needed:"
log_info "  ./resize-image.sh $OUTPUT_IMAGE --boot-size 512"
log_info ""

exit 0
