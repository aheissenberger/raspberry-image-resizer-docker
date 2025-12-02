/**
 * E2E tests for image resize operations
 * Ported from run-test.sh
 */

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { join } from "path";
import {
  buildDockerImage,
  runDockerTest,
  validateSnapshots,
  cleanupSnapshots,
  cleanupTestImages,
  waitForDocker,
  dockerImageExists,
  type SnapshotFiles,
} from "./helpers";

const IMAGE_TAG = "rpi-image-resizer-test";
const TEST_TIMEOUT = 300000; // 5 minutes per test

describe("Image Resize E2E Tests", () => {
  beforeAll(async () => {
    // Check Docker is available
    const dockerReady = await waitForDocker();
    if (!dockerReady) {
      throw new Error(
        "Docker is not available. Please start Docker Desktop and try again."
      );
    }

    // Build Docker image (no cache for clean tests)
    console.log(`\n[E2E] Building Docker image: ${IMAGE_TAG}`);
    const imageExists = await dockerImageExists(IMAGE_TAG);
    if (!imageExists) {
      await buildDockerImage(IMAGE_TAG, true);
      console.log(`[E2E] Docker image built successfully\n`);
    } else {
      console.log(`[E2E] Using existing Docker image\n`);
    }
  }, TEST_TIMEOUT);

  afterAll(async () => {
    // Clean up all test images
    console.log("\n[E2E] Cleaning up test images...");
    await cleanupTestImages([
      "test.img",
      "test-expand.img",
      "test-shrink.img",
      "*.img.*.decompressed_*.img",
    ]);
  });

  test(
    "Test 1: Boot expansion with root move (64MB→256MB boot, no image resize)",
    async () => {
      console.log("\n========================================");
      console.log("TEST 1: Boot expansion with root move");
      console.log("No image size change, boot 64MB→256MB");
      console.log("Root must shrink to accommodate");
      console.log("========================================\n");

      const snapshots: SnapshotFiles = {
        rootPre: join(process.cwd(), "snapshot-pre.txt"),
        rootPost: join(process.cwd(), "snapshot-post.txt"),
        bootPre: join(process.cwd(), "snapshot-boot-pre.txt"),
        bootPost: join(process.cwd(), "snapshot-boot-post.txt"),
      };

      const result = await runDockerTest(IMAGE_TAG, {
        filename: "test.img",
        initialSizeMB: 700,
        bootSizeMB: 256,
        snapshot: true,
        verbose: true,
      });

      // Check test execution succeeded
      if (!result.success) {
        console.error("[E2E] Test failed! Output:", result.output);
      }
      expect(result.success).toBe(true);
      expect(result.output).toContain("[TEST] All done.");

      // Validate file snapshots
      console.log("\n[E2E] Test 1: Comparing pre/post file snapshots...");
      const { rootValid, bootValid } = await validateSnapshots(snapshots);

      expect(rootValid).toBe(true);
      expect(bootValid).toBe(true);

      console.log(
        "[E2E] Test 1: Root file contents unchanged across resize (OK)"
      );
      console.log(
        "[E2E] Test 1: Boot file contents preserved across resize (OK)"
      );

      // Cleanup snapshots
      await cleanupSnapshots(snapshots);

      console.log("[E2E] Test 1: PASSED\n");

      // Geometry assertions (boot/root sizes)
      const sizes = parseSummarySizes(result.output);
      expect(sizes.bootMB).toBeGreaterThan(250); // allow minor rounding/alignment
      expect(sizes.bootMB).toBeLessThan(262); // 256MB target + small tolerance
      // Root should occupy nearly all remaining space
      const expectedRootMin = 430; // relaxed lower bound after auto-grow
      expect(sizes.rootMB).toBeGreaterThan(expectedRootMin);
    },
    TEST_TIMEOUT
  );

  test(
    "Test 2: Image expansion with boot resize (700MB→1500MB, 64MB→256MB boot)",
    async () => {
      console.log("\n========================================");
      console.log("TEST 2: Image expansion with boot resize");
      console.log("Image 700MB→1500MB, boot 64MB→256MB");
      console.log("Root expands to use new space");
      console.log("========================================\n");

      const snapshots: SnapshotFiles = {
        rootPre: join(process.cwd(), "snapshot-pre.txt"),
        rootPost: join(process.cwd(), "snapshot-post.txt"),
        bootPre: join(process.cwd(), "snapshot-boot-pre.txt"),
        bootPost: join(process.cwd(), "snapshot-boot-post.txt"),
      };

      const result = await runDockerTest(IMAGE_TAG, {
        filename: "test-expand.img",
        initialSizeMB: 700,
        targetSizeMB: 1500,
        bootSizeMB: 256,
        snapshot: true,
        verbose: true,
      });

      // Check test execution succeeded
      expect(result.success).toBe(true);
      expect(result.output).toContain("[TEST] All done.");

      // Validate file snapshots
      console.log("\n[E2E] Test 2: Comparing pre/post file snapshots...");
      const { rootValid, bootValid } = await validateSnapshots(snapshots);

      expect(rootValid).toBe(true);
      expect(bootValid).toBe(true);

      console.log(
        "[E2E] Test 2: Root file contents unchanged across resize (OK)"
      );
      console.log(
        "[E2E] Test 2: Boot file contents preserved across resize (OK)"
      );

      // Cleanup snapshots
      await cleanupSnapshots(snapshots);

      console.log("[E2E] Test 2: PASSED\n");

      const sizes = parseSummarySizes(result.output);
      // Expanded image ~1500MB
      expect(sizes.imageMB).toBeGreaterThan(1490);
      expect(sizes.bootMB).toBeGreaterThan(250);
      expect(sizes.bootMB).toBeLessThan(262);
      // Allow alignment & safety buffer (~1MB end + possible rounding): relax by 8MB
      const expectedRootMin = sizes.imageMB - sizes.bootMB - 8;
      expect(sizes.rootMB).toBeGreaterThan(expectedRootMin);
    },
    TEST_TIMEOUT
  );

  test(
    "Test 3: Image shrink without boot change (700MB→600MB, boot stays 64MB)",
    async () => {
      console.log("\n========================================");
      console.log("TEST 3: Image shrink without boot change");
      console.log("Image 700MB→600MB, boot stays 64MB");
      console.log("Root shrinks to fit new image size");
      console.log("========================================\n");

      const snapshots: SnapshotFiles = {
        rootPre: join(process.cwd(), "snapshot-pre.txt"),
        rootPost: join(process.cwd(), "snapshot-post.txt"),
        bootPre: join(process.cwd(), "snapshot-boot-pre.txt"),
        bootPost: join(process.cwd(), "snapshot-boot-post.txt"),
      };

      const result = await runDockerTest(IMAGE_TAG, {
        filename: "test-shrink.img",
        initialSizeMB: 700,
        targetSizeMB: 600,
        freeTailMB: 150,
        bootSizeMB: 64,
        snapshot: true,
        verbose: true,
      });

      // Check test execution succeeded
      expect(result.success).toBe(true);
      expect(result.output).toContain("[TEST] All done.");

      // Validate file snapshots
      console.log("\n[E2E] Test 3: Comparing pre/post file snapshots...");
      const { rootValid, bootValid } = await validateSnapshots(snapshots);

      expect(rootValid).toBe(true);
      expect(bootValid).toBe(true);

      console.log(
        "[E2E] Test 3: Root file contents unchanged across resize (OK)"
      );
      console.log(
        "[E2E] Test 3: Boot file contents preserved across resize (OK)"
      );

      // Cleanup snapshots
      await cleanupSnapshots(snapshots);

      console.log("[E2E] Test 3: PASSED\n");

      const sizes = parseSummarySizes(result.output);
      // Image shrunk to ~600MB
      expect(sizes.imageMB).toBeGreaterThan(590);
      expect(sizes.imageMB).toBeLessThan(610);
      expect(sizes.bootMB).toBeGreaterThan(60);
      expect(sizes.bootMB).toBeLessThan(68);
      const expectedRootMax = sizes.imageMB - sizes.bootMB; // root shrinks
      expect(sizes.rootMB).toBeLessThan(expectedRootMax + 2);
    },
    TEST_TIMEOUT
  );
});

// Helper to parse partition summary lines emitted by worker (verbose mode)
function parseSummarySizes(output: string): { bootMB: number; rootMB: number; imageMB: number } {
  let bootMB = 0, rootMB = 0, imageMB = 0;
  const lines = output.split(/\n/);
  // Primary parse: worker summary lines
  for (const l of lines) {
    const partMatch = l.match(/^\[SUMMARY\] p(\d+): .*sizeMB=(\d+\.\d+)/);
    if (partMatch) {
      const partNum = partMatch[1];
      const mb = parseFloat(partMatch[2]);
      if (partNum === "1") bootMB = mb; else if (partNum === "2") rootMB = mb;
    }
    const imgMatch = l.match(/^\[SUMMARY\] Image Size: .*\((\d+\.\d+) MB/);
    if (imgMatch) imageMB = parseFloat(imgMatch[1]);
  }
  // Fallback: fdisk output parsing if summary absent
  if (bootMB === 0 || rootMB === 0) {
    for (const l of lines) {
      // Image size line: Disk /dev/loop0: 700 MiB, 734003200 bytes, ...
      const diskLine = l.match(/^Disk \S+: (\d+) MiB/);
      if (diskLine) imageMB = parseInt(diskLine[1], 10);
      const devLine = l.match(/^\/dev\/loop\dp(\d+)\s+\*?\s+\d+\s+\d+\s+\d+\s+(\d+)([KMG])\s+/);
      if (devLine) {
        const part = devLine[1];
        let val = parseInt(devLine[2], 10);
        const unit = devLine[3];
        if (unit === 'K') val = val / 1024; // convert to MB
        else if (unit === 'G') val = val * 1024;
        // 'M' already MB
        if (part === '1') bootMB = val; else if (part === '2') rootMB = val;
      }
    }
  }
  return { bootMB, rootMB, imageMB };
}
