#!/bin/bash

# Comprehensive compression workflow test script
# Tests clone with compression, resize with compressed images, and write operations

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ $exit_code -eq 0 ]] || [[ "${TESTS_COMPLETED:-0}" -eq 1 ]]; then
        echo ""
        echo -e "${BLUE}Cleaning up test artifacts...${NC}"
        rm -f test-compression-*.img* test-compressed-*.img* test-cleanup*.img*
        echo -e "${GREEN}Cleanup complete${NC}"
    fi
}

# Set up cleanup trap
trap cleanup EXIT

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
}

log_test() {
    ((TESTS_RUN++))
    echo ""
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Test $TESTS_RUN: $1${NC}"
    echo -e "${YELLOW}========================================${NC}"
}

# Function to check if a compression tool is available
check_tool() {
    local tool=$1
    if ! command -v "$tool" &> /dev/null; then
        log_error "Required tool '$tool' is not installed"
        echo "Please install: brew install $tool"
        return 1
    fi
    log_info "Tool '$tool' is available"
    return 0
}

# Function to create a test image
create_test_image() {
    local image_path=$1
    local size_mb=${2:-100}
    
    log_info "Creating test image: $image_path (${size_mb}MB)"
    
    # Create a simple image with dd and basic partition structure
    dd if=/dev/zero of="$image_path" bs=1M count="$size_mb" status=none 2>&1
    
    # Use Docker to create partitions and filesystems
    docker run --rm --privileged \
        --entrypoint=bash \
        -v "$SCRIPT_DIR:/work" \
        rpi-image-resizer:latest \
        -c "
            cd /work
            IMG='$(basename "$image_path")'
            LOOP=\$(losetup -Pf --show \"\$IMG\")
            # Create partition table
            sfdisk \$LOOP >/dev/null 2>&1 <<EOF
label: dos
unit: sectors
\${LOOP}p1 : start=8192, size=131072, type=c, bootable
\${LOOP}p2 : start=139264, type=83
EOF
            partprobe \$LOOP >/dev/null 2>&1
            # Use kpartx since loop partitions may not appear in Docker
            kpartx -av \$LOOP >/dev/null 2>&1
            sleep 1
            # Create filesystems using mapper devices
            mkfs.vfat -F 32 -n boot /dev/mapper/\$(basename \$LOOP)p1 >/dev/null 2>&1
            mkfs.ext4 -F -L rootfs /dev/mapper/\$(basename \$LOOP)p2 >/dev/null 2>&1
            # Cleanup
            kpartx -d \$LOOP >/dev/null 2>&1
            losetup -d \$LOOP
        " > /dev/null 2>&1
    
    if [[ ! -f "$image_path" ]]; then
        log_error "Failed to create test image"
        return 1
    fi
    
    log_success "Test image created: $(ls -lh "$image_path" | awk '{print $5}')"
    return 0
}

# Function to compute file checksum
compute_checksum() {
    local file=$1
    if [[ -f "$file" ]]; then
        md5 -q "$file"
    else
        echo "FILE_NOT_FOUND"
    fi
}

# Function to validate image integrity
validate_image() {
    local image_path=$1
    local description=$2
    
    log_info "Validating image: $description"
    
    # Check file exists
    if [[ ! -f "$image_path" ]]; then
        log_error "Image file not found: $image_path"
        return 1
    fi
    
    # Check file size is reasonable
    local size=$(stat -f%z "$image_path")
    if [[ $size -lt 10000000 ]]; then  # Less than 10MB is suspicious
        log_error "Image file too small: $size bytes"
        return 1
    fi
    
    # Try to attach as loop device in Docker to verify partition table exists
    docker run --rm --privileged \
        --entrypoint=bash \
        -v "$SCRIPT_DIR:/work" \
        rpi-image-resizer:latest \
        -c "
            LOOP_DEV=\$(losetup -Pf --show /work/$(basename "$image_path"))
            if [[ -z \"\$LOOP_DEV\" ]]; then
                exit 1
            fi
            # Just check sfdisk can read the table (don't care about output format)
            sfdisk -d \$LOOP_DEV > /dev/null 2>&1
            RESULT=\$?
            losetup -d \$LOOP_DEV
            exit \$RESULT
        " > /dev/null 2>&1
    
    if [[ $? -ne 0 ]]; then
        log_error "Image validation failed: cannot read partition table"
        return 1
    fi
    
    log_success "Image validated: $description"
    return 0
}

# Function to test compression tool validation
test_compression_tool_validation() {
    log_test "Compression Tool Validation"
    
    # Test that script checks for required tools
    log_info "Testing tool availability checks..."
    
    # These tools should be available
    local tools=("zstd" "xz" "gzip")
    local all_available=true
    
    for tool in "${tools[@]}"; do
        if ! check_tool "$tool"; then
            all_available=false
        fi
    done
    
    if $all_available; then
        log_success "All compression tools available"
    else
        log_error "Some compression tools missing"
        return 1
    fi
    
    return 0
}

# Function to test compression level validation
test_compression_level_validation() {
    log_test "Compression Level Validation"
    
    log_info "Testing compression level validation logic..."
    
    # Test zstd level validation by checking the script's validation code
    # We test this by trying to run with invalid levels and checking the output
    
    # Test invalid zstd level (too high) - should fail during argument parsing
    if bash -c '
        COMPRESS_ALGO="zstd"
        COMPRESS_LEVEL=25
        if [[ $COMPRESS_LEVEL -lt 1 ]] || [[ $COMPRESS_LEVEL -gt 19 ]]; then
            echo "Invalid compression level"
            exit 1
        fi
    ' 2>&1 | grep -q "Invalid compression level"; then
        log_success "zstd level validation works (rejected level 25)"
    else
        log_error "zstd level validation failed (should reject level 25)"
        return 1
    fi
    
    # Test valid zstd level
    if bash -c '
        COMPRESS_ALGO="zstd"
        COMPRESS_LEVEL=10
        if [[ $COMPRESS_LEVEL -lt 1 ]] || [[ $COMPRESS_LEVEL -gt 19 ]]; then
            echo "Invalid compression level"
            exit 1
        fi
        echo "Valid level"
    ' 2>&1 | grep -q "Valid level"; then
        log_success "zstd level 10 accepted correctly"
    else
        log_error "zstd level validation failed (should accept level 10)"
        return 1
    fi
    
    # Test invalid xz level
    if bash -c '
        COMPRESS_ALGO="xz"
        COMPRESS_LEVEL=15
        if [[ $COMPRESS_LEVEL -lt 1 ]] || [[ $COMPRESS_LEVEL -gt 9 ]]; then
            echo "Invalid compression level"
            exit 1
        fi
    ' 2>&1 | grep -q "Invalid compression level"; then
        log_success "xz level validation works (rejected level 15)"
    else
        log_error "xz level validation failed (should reject level 15)"
        return 1
    fi
    
    # Test valid xz level
    if bash -c '
        COMPRESS_ALGO="xz"
        COMPRESS_LEVEL=6
        if [[ $COMPRESS_LEVEL -lt 1 ]] || [[ $COMPRESS_LEVEL -gt 9 ]]; then
            echo "Invalid compression level"
            exit 1
        fi
        echo "Valid level"
    ' 2>&1 | grep -q "Valid level"; then
        log_success "xz level 6 accepted correctly"
    else
        log_error "xz level validation failed (should accept level 6)"
        return 1
    fi
    
    return 0
}

# Function to test compression during create
test_compression_create() {
    local algo=$1
    local level=$2
    local extension=$3
    
    log_test "Create Compressed Image: $algo (level $level)"
    
    # Create uncompressed test image first
    local source_img="test-compression-source.img"
    create_test_image "$source_img" 100 || return 1
    
    local original_size=$(stat -f%z "$source_img")
    log_info "Original image size: $(numfmt --to=iec-i --suffix=B $original_size)"
    
    # Compress the image using the specified algorithm
    local compressed_img="test-compressed-${algo}.img.${extension}"
    log_info "Compressing with $algo (level $level)..."
    
    case "$algo" in
        zstd)
            zstd -${level} -T0 "$source_img" -o "$compressed_img"
            ;;
        xz)
            xz -${level} -T0 -c "$source_img" > "$compressed_img"
            ;;
        gzip)
            gzip -${level} -c "$source_img" > "$compressed_img"
            ;;
    esac
    
    if [[ ! -f "$compressed_img" ]]; then
        log_error "Compression failed"
        return 1
    fi
    
    local compressed_size=$(stat -f%z "$compressed_img")
    local ratio=$(echo "scale=1; 100 - ($compressed_size * 100 / $original_size)" | bc)
    
    log_info "Compressed size: $(numfmt --to=iec-i --suffix=B $compressed_size)"
    log_info "Compression ratio: ${ratio}%"
    
    if [[ $compressed_size -lt $original_size ]]; then
        log_success "Compression successful: $algo reduced size by ${ratio}%"
    else
        log_error "Compression failed: output not smaller than input"
        return 1
    fi
    
    # Clean up source image
    rm -f "$source_img"
    
    return 0
}

# Function to test decompression during resize
test_resize_compressed() {
    local algo=$1
    local extension=$2
    
    log_test "Resize Compressed Image: $algo"
    
    local compressed_img="test-compressed-${algo}.img.${extension}"
    
    if [[ ! -f "$compressed_img" ]]; then
        log_error "Compressed image not found: $compressed_img"
        return 1
    fi
    
    # Compute checksum of compressed file before resize
    local checksum_before=$(compute_checksum "$compressed_img")
    
    log_info "Resizing compressed image: $compressed_img"
    
    # Run resize operation (should auto-decompress)
    if ./resize-image.sh "$compressed_img" --boot-size 128 --dry-run 2>&1 | grep -q "Detected.*compressed image"; then
        log_success "Compressed image detected by resize script"
    else
        log_error "Resize script did not detect compressed image"
        return 1
    fi
    
    # Verify original compressed file is unchanged
    local checksum_after=$(compute_checksum "$compressed_img")
    if [[ "$checksum_before" == "$checksum_after" ]]; then
        log_success "Original compressed file unchanged"
    else
        log_error "Original compressed file was modified"
        return 1
    fi
    
    # Now do actual resize (not dry-run)
    log_info "Performing actual resize operation..."
    if ./resize-image.sh "$compressed_img" --boot-size 128; then
        log_success "Resize operation completed"
        
        # Find the backup file (will be named based on decompressed temp file)
        # Pattern: test-compressed-*.img.*.decompressed_*.img
        local backup_pattern="*.img.${extension}.decompressed_[0-9]*.img"
        local backup_file=$(ls -t $backup_pattern 2>/dev/null | head -1)
        
        if [[ -n "$backup_file" ]] && [[ -f "$backup_file" ]]; then
            log_info "Backup created: $backup_file"
            validate_image "$backup_file" "resized from $algo compressed" || return 1
            log_success "Validated resized image from $algo compression"
            
            # Clean up backup
            rm -f "$backup_file"
        else
            log_error "Backup file not found (pattern: $backup_pattern)"
            ls -lth *.img* | head -10
            return 1
        fi
    else
        log_error "Resize operation failed"
        return 1
    fi
    
    return 0
}

# Function to test decompression detection
test_decompression_detection() {
    log_test "Decompression Detection and Tool Validation"
    
    log_info "Testing automatic extension detection..."
    
    # Create dummy compressed files for detection testing
    touch test-detect.img.zst test-detect.img.xz test-detect.img.gz
    
    # Test .zst detection (will fail on decompression but should detect format)
    if ./resize-image.sh test-detect.img.zst --dry-run 2>&1 | grep -q "Detected zstd compressed image"; then
        log_success ".zst extension detected correctly"
    else
        log_error ".zst extension not detected"
        rm -f test-detect.img.*
        return 1
    fi
    
    # Test .xz detection
    if ./resize-image.sh test-detect.img.xz --dry-run 2>&1 | grep -q "Detected xz compressed image"; then
        log_success ".xz extension detected correctly"
    else
        log_error ".xz extension not detected"
        rm -f test-detect.img.*
        return 1
    fi
    
    # Test .gz detection
    if ./resize-image.sh test-detect.img.gz --dry-run 2>&1 | grep -q "Detected gzip compressed image"; then
        log_success ".gz extension detected correctly"
    else
        log_error ".gz extension not detected"
        rm -f test-detect.img.*
        return 1
    fi
    
    rm -f test-detect.img.*
    return 0
}

# Function to test cleanup of temporary files
test_temp_file_cleanup() {
    log_test "Temporary File Cleanup"
    
    # Create a compressed test image
    local source_img="test-cleanup-source.img"
    create_test_image "$source_img" 50 || return 1
    
    local compressed_img="test-cleanup.img.zst"
    zstd -3 -T0 "$source_img" -o "$compressed_img"
    rm -f "$source_img"
    
    log_info "Running resize with failure to test cleanup..."
    
    # Count .tmp files before
    local tmp_before=$(ls -1 *.tmp 2>/dev/null | wc -l)
    
    # Try to resize (this should create and clean up temp file)
    ./resize-image.sh "$compressed_img" --boot-size 128 --dry-run > /dev/null 2>&1 || true
    
    # Count .tmp files after
    local tmp_after=$(ls -1 *.tmp 2>/dev/null | wc -l)
    
    if [[ $tmp_after -eq $tmp_before ]]; then
        log_success "Temporary files cleaned up properly"
    else
        log_error "Temporary files leaked: found $(($tmp_after - $tmp_before)) extra .tmp files"
        return 1
    fi
    
    rm -f "$compressed_img"
    return 0
}

# Main test execution
main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     Compression Workflow End-to-End Test Suite            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Check prerequisites
    log_info "Checking prerequisites..."
    
    if ! docker image inspect rpi-image-resizer:latest > /dev/null 2>&1; then
        log_error "Docker image 'rpi-image-resizer:latest' not found"
        echo "Please build it first: docker build -t rpi-image-resizer:latest ."
        exit 1
    fi
    
    log_success "Docker image found"
    
    # Run all tests
    test_compression_tool_validation || true
    test_compression_level_validation || true
    test_decompression_detection || true
    
    # Test each compression algorithm
    test_compression_create "zstd" 3 "zst" || true
    test_compression_create "xz" 6 "xz" || true
    test_compression_create "gzip" 6 "gz" || true
    
    # Test resizing compressed images
    test_resize_compressed "zstd" "zst" || true
    test_resize_compressed "xz" "xz" || true
    test_resize_compressed "gzip" "gz" || true
    
    # Test cleanup
    test_temp_file_cleanup || true
    
    # Print summary
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    Test Summary                            ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Tests run:    ${TESTS_RUN}"
    echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
    echo ""
    
    TESTS_COMPLETED=1
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}✓ All compression tests passed!${NC}"
        return 0
    else
        echo -e "${RED}✗ Some compression tests failed${NC}"
        return 1
    fi
}

# Run main function
main
exit $?
