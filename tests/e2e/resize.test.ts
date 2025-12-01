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

const IMAGE_TAG = "rpi-resizer-slim";
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
    },
    TEST_TIMEOUT
  );
});
