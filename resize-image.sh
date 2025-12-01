#!/bin/bash

# Raspberry Pi Image Resizer - Host Launcher Script
# Runs on macOS and orchestrates the Docker-based resizing process

set -e

# Configuration
DOCKER_IMAGE="rpi-image-resizer:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

show_usage() {
    cat << EOF
Usage: $0 <path-to-image> [options]

Resize Raspberry Pi disk images safely using Docker.

Arguments:
  <path-to-image>          Path to the Raspberry Pi .img file (required)

Options:
  --boot-size <MB>         Size for boot partition in MB (default: 256)
  --image-size <size>      Resize overall image file (e.g., 32GB, 64GB, 128GB)
                           Automatically adjusts root partition after boot resize
  --unsafe-resize-ext4     Enable ext4 root partition resizing (dangerous!)
  --dry-run               Preview changes without modifying the image
  --verbose               Show detailed output from Docker container
  -h, --help              Show this help message

Examples:
  $0 raspios.img
  $0 raspios.img --boot-size 512
  $0 raspios.img --image-size 64GB
  $0 raspios.img --boot-size 512 --image-size 64GB

EOF
    exit 0
}

# Parse arguments
IMAGE_PATH=""
BOOT_SIZE=256
IMAGE_SIZE=""
UNSAFE_RESIZE_EXT4=0
DRY_RUN=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            ;;
        --boot-size)
            BOOT_SIZE="$2"
            shift 2
            ;;
        --image-size)
            IMAGE_SIZE="$2"
            shift 2
            ;;
        --unsafe-resize-ext4)
            UNSAFE_RESIZE_EXT4=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        *)
            if [[ -z "$IMAGE_PATH" ]]; then
                IMAGE_PATH="$1"
            else
                log_error "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "$IMAGE_PATH" ]]; then
    log_error "Missing required argument: <path-to-image>"
    echo ""
    show_usage
fi

# Validate image file exists
if [[ ! -f "$IMAGE_PATH" ]]; then
    log_error "Image file not found: $IMAGE_PATH"
    exit 1
fi

# Variables for compressed input handling
TEMP_IMAGE=""
ORIGINAL_IMAGE="$IMAGE_PATH"

# Function to check if a compression tool is available
# Parameters:
#   $1 - tool name (zstd, xz, gzip)
# Returns: 0 if available, 1 if not
check_decompression_tool() {
    local tool="$1"
    
    if ! command -v "$tool" &> /dev/null; then
        log_error "Decompression tool '$tool' is not installed"
        log_error "Please install it:"
        case "$tool" in
            zstd)
                log_error "  macOS: brew install zstd"
                ;;
            xz)
                log_error "  macOS: brew install xz"
                ;;
            gzip)
                log_error "  gzip should be pre-installed on macOS"
                ;;
        esac
        return 1
    fi
    return 0
}

# Function to decompress input image if needed
# Detects compressed files by extension and decompresses to a temporary file
# Updates IMAGE_PATH to point to the decompressed file
# Returns: 0 on success, 1 on failure
handle_compressed_input() {
    case "$IMAGE_PATH" in
        *.zst)
            log_info "Detected zstd compressed image"
            check_decompression_tool "zstd" || return 1
            
            TEMP_IMAGE="${IMAGE_PATH}.decompressed.tmp"
            log_info "Decompressing to: $TEMP_IMAGE"
            
            if ! zstd -dc "$IMAGE_PATH" > "$TEMP_IMAGE"; then
                log_error "Failed to decompress zstd image"
                return 1
            fi
            
            IMAGE_PATH="$TEMP_IMAGE"
            log_info "Decompression complete"
            ;;
        *.xz)
            log_info "Detected xz compressed image"
            check_decompression_tool "xz" || return 1
            
            TEMP_IMAGE="${IMAGE_PATH}.decompressed.tmp"
            log_info "Decompressing to: $TEMP_IMAGE"
            
            if ! xz -dc "$IMAGE_PATH" > "$TEMP_IMAGE"; then
                log_error "Failed to decompress xz image"
                return 1
            fi
            
            IMAGE_PATH="$TEMP_IMAGE"
            log_info "Decompression complete"
            ;;
        *.gz)
            log_info "Detected gzip compressed image"
            check_decompression_tool "gzip" || return 1
            
            TEMP_IMAGE="${IMAGE_PATH}.decompressed.tmp"
            log_info "Decompressing to: $TEMP_IMAGE"
            
            if ! gzip -dc "$IMAGE_PATH" > "$TEMP_IMAGE"; then
                log_error "Failed to decompress gzip image"
                return 1
            fi
            
            IMAGE_PATH="$TEMP_IMAGE"
            log_info "Decompression complete"
            ;;
    esac
    return 0
}

# Cleanup function to remove temporary files
cleanup() {
    if [[ -n "$TEMP_IMAGE" ]] && [[ -f "$TEMP_IMAGE" ]]; then
        log_info "Cleaning up temporary decompressed file"
        rm -f "$TEMP_IMAGE"
    fi
}

# Set up cleanup trap
trap cleanup EXIT

# Handle compressed input
if ! handle_compressed_input; then
    exit 1
fi

# Function to resize Raspberry Pi image
# Parameters:
#   $1 - Image path
#   $2 - Boot size in MB
# Returns: 0 on success, non-zero on failure
resize_raspberry_pi_image() {
    local image_path="$1"
    local boot_size="$2"
    
    # Convert to absolute path
    image_path="$(cd "$(dirname "$image_path")" && pwd)/$(basename "$image_path")"
    local image_dir="$(dirname "$image_path")"
    local image_name="$(basename "$image_path")"

    log_info "Raspberry Pi Image Resizer"
    log_info "=========================="
    log_info "Image: $image_path"
    log_info "Boot partition size: ${boot_size}MB"
    [[ -n "$IMAGE_SIZE" ]] && log_info "Target image size: $IMAGE_SIZE"
    [[ $UNSAFE_RESIZE_EXT4 -eq 1 ]] && log_warn "Unsafe ext4 resizing ENABLED"
    [[ $DRY_RUN -eq 1 ]] && log_warn "DRY RUN mode - no modifications will be made"

    # Check if Docker is running
    if ! docker info > /dev/null 2>&1; then
        log_error "Docker is not running. Please start Docker Desktop."
        return 1
    fi

    # Check if Docker image exists
    if ! docker image inspect "$DOCKER_IMAGE" > /dev/null 2>&1; then
        log_warn "Docker image '$DOCKER_IMAGE' not found. Building..."
        cd "$SCRIPT_DIR"
        docker build -t "$DOCKER_IMAGE" .
        if [[ $? -ne 0 ]]; then
            log_error "Failed to build Docker image"
            return 1
        fi
        log_info "Docker image built successfully"
    fi

    # Create backup with timestamp
    local timestamp=$(date +%Y%m%d%H%M)
    local backup_name="${image_name%.*}_${timestamp}.img"
    local backup_path="$image_dir/$backup_name"
    local work_image

    if [[ $DRY_RUN -eq 0 ]]; then
        log_info "Creating backup: $backup_name"
        cp "$image_path" "$backup_path"
        
        if [[ $? -ne 0 ]]; then
            log_error "Failed to create backup"
            return 1
        fi
        
        log_info "Backup created successfully"
        work_image="$backup_name"
    else
        log_info "Dry run mode - using original image (read-only)"
        work_image="$image_name"
    fi

    # Build Docker run command
    local docker_cmd="docker run --rm --privileged"

    # Add volume mount
    docker_cmd="$docker_cmd -v \"$image_dir:/work\""

    # Add environment variables
    docker_cmd="$docker_cmd -e IMAGE_FILE=\"$work_image\""
    docker_cmd="$docker_cmd -e BOOT_SIZE_MB=\"$boot_size\""
    [[ -n "$IMAGE_SIZE" ]] && docker_cmd="$docker_cmd -e IMAGE_SIZE=\"$IMAGE_SIZE\""
    docker_cmd="$docker_cmd -e UNSAFE_RESIZE_EXT4=\"$UNSAFE_RESIZE_EXT4\""
    docker_cmd="$docker_cmd -e DRY_RUN=\"$DRY_RUN\""
    docker_cmd="$docker_cmd -e VERBOSE=\"$VERBOSE\""

    # Add image name
    docker_cmd="$docker_cmd \"$DOCKER_IMAGE\""

    # Run Docker container
    log_info "Starting Docker container..."
    eval $docker_cmd

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_info "Operation completed successfully!"
        if [[ $DRY_RUN -eq 0 ]]; then
            log_info "Modified image: $backup_path"
            log_info "Original image unchanged: $image_path"
        fi
        return 0
    else
        log_error "Operation failed with exit code $exit_code"
        if [[ $DRY_RUN -eq 0 ]]; then
            log_warn "Backup preserved at: $backup_path"
        fi
        return $exit_code
    fi
}

# Main execution
resize_raspberry_pi_image "$IMAGE_PATH" "$BOOT_SIZE"
exit $?
