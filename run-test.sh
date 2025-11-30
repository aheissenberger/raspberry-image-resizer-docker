#!/bin/zsh
set -euo pipefail

# Convenience script to build and run the in-container test harness
# Requires Docker Desktop running and privileged mode for loop/kpartx.

IMAGE_TAG="rpi-resizer-slim"

echo "[RUN-TEST] Building Docker image (no-cache): ${IMAGE_TAG}"
docker build --no-cache -t "${IMAGE_TAG}" .

echo "[RUN-TEST] Running in-container test (creates 700MB test.img, resizes boot to 256MB)"
docker run --rm --privileged \
  --entrypoint /usr/local/bin/test-create-and-resize.sh \
  -v "$PWD":/work \
  -e IMAGE_FILE=test.img \
  -e BOOT_SIZE_MB=256 \
  -e SNAPSHOT=1 \
  -e VERBOSE=1 \
  "${IMAGE_TAG}"

echo "[RUN-TEST] Comparing pre/post file snapshots..."

# Check root partition snapshots
if [[ -f snapshot-pre.txt && -f snapshot-post.txt ]]; then
  if diff -u snapshot-pre.txt snapshot-post.txt >/dev/null; then
    echo "[SANITY] Root file contents unchanged across resize (OK)"
  else
    echo "[SANITY] Root differences detected between pre and post snapshots!" >&2
    diff -u snapshot-pre.txt snapshot-post.txt || true
    exit 1
  fi
else
  echo "[SANITY] Root snapshot files missing; skipping root diff" >&2
fi

# Check boot partition snapshots
if [[ -f snapshot-boot-pre.txt && -f snapshot-boot-post.txt ]]; then
  if diff -u snapshot-boot-pre.txt snapshot-boot-post.txt >/dev/null; then
    echo "[SANITY] Boot file contents preserved across resize (OK)"
  else
    echo "[SANITY] Boot differences detected between pre and post snapshots!" >&2
    diff -u snapshot-boot-pre.txt snapshot-boot-post.txt || true
    exit 1
  fi
else
  echo "[SANITY] Boot snapshot files missing; skipping boot diff" >&2
fi

echo "[RUN-TEST] Cleaning up snapshot files..."
rm -f snapshot-pre.txt snapshot-post.txt snapshot-boot-pre.txt snapshot-boot-post.txt

echo "[RUN-TEST] Completed. Inspect /work/test.img and logs above."
