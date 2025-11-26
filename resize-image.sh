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
  --unsafe-resize-ext4     Enable ext4 root partition resizing (dangerous!)
  --dry-run               Preview changes without modifying the image
  --verbose               Show detailed output from Docker container
  -h, --help              Show this help message

Examples:
  $0 raspios.img
  $0 raspios.img --boot-size 512
  $0 raspios.img --boot-size 512 --unsafe-resize-ext4

EOF
    exit 0
}

# Parse arguments
IMAGE_PATH=""
BOOT_SIZE=256
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

# Convert to absolute path
IMAGE_PATH="$(cd "$(dirname "$IMAGE_PATH")" && pwd)/$(basename "$IMAGE_PATH")"
IMAGE_DIR="$(dirname "$IMAGE_PATH")"
IMAGE_NAME="$(basename "$IMAGE_PATH")"

log_info "Raspberry Pi Image Resizer"
log_info "=========================="
log_info "Image: $IMAGE_PATH"
log_info "Boot partition size: ${BOOT_SIZE}MB"
[[ $UNSAFE_RESIZE_EXT4 -eq 1 ]] && log_warn "Unsafe ext4 resizing ENABLED"
[[ $DRY_RUN -eq 1 ]] && log_warn "DRY RUN mode - no modifications will be made"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    log_error "Docker is not running. Please start Docker Desktop."
    exit 1
fi

# Check if Docker image exists
if ! docker image inspect "$DOCKER_IMAGE" > /dev/null 2>&1; then
    log_warn "Docker image '$DOCKER_IMAGE' not found. Building..."
    cd "$SCRIPT_DIR"
    docker build -t "$DOCKER_IMAGE" .
    if [[ $? -ne 0 ]]; then
        log_error "Failed to build Docker image"
        exit 1
    fi
    log_info "Docker image built successfully"
fi

# Create backup with timestamp
TIMESTAMP=$(date +%Y%m%d%H%M)
BACKUP_NAME="${IMAGE_NAME%.*}_${TIMESTAMP}.img"
BACKUP_PATH="$IMAGE_DIR/$BACKUP_NAME"

if [[ $DRY_RUN -eq 0 ]]; then
    log_info "Creating backup: $BACKUP_NAME"
    cp "$IMAGE_PATH" "$BACKUP_PATH"
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to create backup"
        exit 1
    fi
    
    log_info "Backup created successfully"
    WORK_IMAGE="$BACKUP_NAME"
else
    log_info "Dry run mode - using original image (read-only)"
    WORK_IMAGE="$IMAGE_NAME"
fi

# Build Docker run command
DOCKER_CMD="docker run --rm --privileged"

# Add volume mount
DOCKER_CMD="$DOCKER_CMD -v \"$IMAGE_DIR:/work\""

# Add environment variables
DOCKER_CMD="$DOCKER_CMD -e IMAGE_FILE=\"$WORK_IMAGE\""
DOCKER_CMD="$DOCKER_CMD -e BOOT_SIZE_MB=\"$BOOT_SIZE\""
DOCKER_CMD="$DOCKER_CMD -e UNSAFE_RESIZE_EXT4=\"$UNSAFE_RESIZE_EXT4\""
DOCKER_CMD="$DOCKER_CMD -e DRY_RUN=\"$DRY_RUN\""
DOCKER_CMD="$DOCKER_CMD -e VERBOSE=\"$VERBOSE\""

# Add image name
DOCKER_CMD="$DOCKER_CMD \"$DOCKER_IMAGE\""

# Run Docker container
log_info "Starting Docker container..."
eval $DOCKER_CMD

EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    log_info "Operation completed successfully!"
    if [[ $DRY_RUN -eq 0 ]]; then
        log_info "Modified image: $BACKUP_PATH"
        log_info "Original image unchanged: $IMAGE_PATH"
    fi
else
    log_error "Operation failed with exit code $EXIT_CODE"
    if [[ $DRY_RUN -eq 0 ]]; then
        log_warn "Backup preserved at: $BACKUP_PATH"
    fi
    exit $EXIT_CODE
fi
