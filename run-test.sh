#!/bin/zsh
set -euo pipefail

# Convenience script to build and run the in-container test harness
# Requires Docker Desktop running and privileged mode for loop/kpartx.

IMAGE_TAG="rpi-resizer-slim"

# Helper function to check snapshots
check_snapshots() {
  local test_name=$1
  
  # Check root partition snapshots
  if [[ -f snapshot-pre.txt && -f snapshot-post.txt ]]; then
    if diff -u snapshot-pre.txt snapshot-post.txt >/dev/null; then
      echo "[SANITY] ${test_name}: Root file contents unchanged across resize (OK)"
    else
      echo "[SANITY] ${test_name}: Root differences detected between pre and post snapshots!" >&2
      diff -u snapshot-pre.txt snapshot-post.txt || true
      return 1
    fi
  else
    echo "[SANITY] ${test_name}: Root snapshot files missing; skipping root diff" >&2
  fi

  # Check boot partition snapshots
  if [[ -f snapshot-boot-pre.txt && -f snapshot-boot-post.txt ]]; then
    if diff -u snapshot-boot-pre.txt snapshot-boot-post.txt >/dev/null; then
      echo "[SANITY] ${test_name}: Boot file contents preserved across resize (OK)"
    else
      echo "[SANITY] ${test_name}: Boot differences detected between pre and post snapshots!" >&2
      diff -u snapshot-boot-pre.txt snapshot-boot-post.txt || true
      return 1
    fi
  else
    echo "[SANITY] ${test_name}: Boot snapshot files missing; skipping boot diff" >&2
  fi
  
  return 0
}

# Cleanup function
cleanup_snapshots() {
  rm -f snapshot-pre.txt snapshot-post.txt snapshot-boot-pre.txt snapshot-boot-post.txt
}

echo "[RUN-TEST] Building Docker image (no-cache): ${IMAGE_TAG}"
docker build --no-cache -t "${IMAGE_TAG}" .

echo ""
echo "=========================================="
echo "TEST 1: Boot expansion with root move"
echo "No image size change, boot 64MB→256MB"
echo "Root must shrink to accommodate"
echo "=========================================="
docker run --rm --privileged \
  --entrypoint /usr/local/bin/test-create-and-resize.sh \
  -v "$PWD":/work \
  -e IMAGE_FILE=test.img \
  -e BOOT_SIZE_MB=256 \
  -e SNAPSHOT=1 \
  -e VERBOSE=1 \
  "${IMAGE_TAG}"

echo "[RUN-TEST] Test 1: Comparing pre/post file snapshots..."
if check_snapshots "Test 1"; then
  cleanup_snapshots
  echo "[RUN-TEST] Test 1: PASSED"
else
  cleanup_snapshots
  echo "[RUN-TEST] Test 1: FAILED" >&2
  exit 1
fi

echo ""
echo "=========================================="
echo "TEST 2: Image expansion with boot resize"
echo "Image 700MB→1500MB, boot 64MB→256MB"
echo "Root expands to use new space"
echo "=========================================="
docker run --rm --privileged \
  --entrypoint /usr/local/bin/test-create-and-resize.sh \
  -v "$PWD":/work \
  -e IMAGE_FILE=test-expand.img \
  -e INITIAL_IMAGE_MB=700 \
  -e TARGET_IMAGE_MB=1500 \
  -e BOOT_SIZE_MB=256 \
  -e SNAPSHOT=1 \
  -e VERBOSE=1 \
  "${IMAGE_TAG}"

echo "[RUN-TEST] Test 2: Comparing pre/post file snapshots..."
if check_snapshots "Test 2"; then
  cleanup_snapshots
  echo "[RUN-TEST] Test 2: PASSED"
else
  cleanup_snapshots
  echo "[RUN-TEST] Test 2: FAILED" >&2
  exit 1
fi

echo ""
echo "=========================================="
echo "TEST 3: Image shrink without boot change"
echo "Image 700MB→600MB, boot stays 64MB"
echo "Root shrinks to fit new image size"
echo "=========================================="
docker run --rm --privileged \
  --entrypoint /usr/local/bin/test-create-and-resize.sh \
  -v "$PWD":/work \
  -e IMAGE_FILE=test-shrink.img \
  -e INITIAL_IMAGE_MB=700 \
  -e TARGET_IMAGE_MB=600 \
  -e FREE_TAIL_MB=150 \
  -e BOOT_SIZE_MB=64 \
  -e SNAPSHOT=1 \
  -e VERBOSE=1 \
  "${IMAGE_TAG}"

echo "[RUN-TEST] Test 3: Comparing pre/post file snapshots..."
if check_snapshots "Test 3"; then
  cleanup_snapshots
  echo "[RUN-TEST] Test 3: PASSED"
else
  cleanup_snapshots
  echo "[RUN-TEST] Test 3: FAILED" >&2
  exit 1
fi

echo ""
echo "=========================================="
echo "ALL TESTS PASSED"
echo "=========================================="
echo "[RUN-TEST] Completed. Inspect test*.img and logs above."
