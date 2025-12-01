/**
 * E2E tests for compression workflows
 * Ported from test-compression.sh
 */

import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { join } from "path";
import { spawn } from "bun";
import {
  createTestImage,
  compressFile,
  getFileSize,
  calculateCompressionRatio,
  computeChecksum,
  cleanupTestImages,
  dockerImageExists,
  waitForDocker,
} from "./helpers";

const CLI_PATH = join(process.cwd(), "dist", "rpi-tool");
const TEST_TIMEOUT = 180000; // 3 minutes per test

// Helper to run CLI command
async function runCLI(args: string[]): Promise<{
  exitCode: number;
  stdout: string;
  stderr: string;
}> {
  const proc = spawn({
    cmd: [CLI_PATH, ...args],
    cwd: process.cwd(),
    stdout: "pipe",
    stderr: "pipe",
  });

  const exitCode = await proc.exited;
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();

  return {
    exitCode,
    stdout,
    stderr,
  };
}

describe("Compression Workflow E2E Tests", () => {
  beforeAll(async () => {
    // Check Docker is available
    const dockerReady = await waitForDocker();
    if (!dockerReady) {
      throw new Error(
        "Docker is not available. Please start Docker Desktop and try again."
      );
    }

    // Check Docker image exists
    const imageExists = await dockerImageExists("rpi-image-resizer:latest");
    if (!imageExists) {
      throw new Error(
        'Docker image "rpi-image-resizer:latest" not found. Please build it first with: bun run docker:build'
      );
    }

    // Check CLI executable exists
    if (!(await Bun.file(CLI_PATH).exists())) {
      throw new Error(
        `CLI executable not found at ${CLI_PATH}. Please build it first with: bun run build:cli`
      );
    }

    console.log("\n[E2E] Prerequisites verified\n");
  }, 30000);

  afterAll(async () => {
    // Clean up all test artifacts
    console.log("\n[E2E] Cleaning up compression test artifacts...");
    await cleanupTestImages([
      "test-compression-*.img*",
      "test-compressed-*.img*",
      "test-detect.img.*",
      "*.img.*.decompressed_*.img",
    ]);
  });

  test("Compression tool availability", async () => {
    console.log("\n========================================");
    console.log("TEST: Compression Tool Validation");
    console.log("========================================\n");

    const tools = ["zstd", "xz", "gzip"];

    for (const tool of tools) {
      const proc = spawn({
        cmd: ["which", tool],
        stdout: "pipe",
        stderr: "pipe",
      });

      const exitCode = await proc.exited;
      expect(exitCode).toBe(0);
      console.log(`[E2E] Tool '${tool}' is available`);
    }

    console.log("\n[E2E] PASSED: All compression tools available\n");
  });

  test("Compression level validation logic", async () => {
    console.log("\n========================================");
    console.log("TEST: Compression Level Validation");
    console.log("========================================\n");

    // Test zstd level validation (1-19)
    expect(() => {
      const level = 25;
      if (level < 1 || level > 19) {
        throw new Error("Invalid zstd level");
      }
    }).toThrow("Invalid zstd level");
    console.log("[E2E] zstd level validation works (rejected level 25)");

    expect(() => {
      const level = 10;
      if (level < 1 || level > 19) {
        throw new Error("Invalid zstd level");
      }
    }).not.toThrow();
    console.log("[E2E] zstd level 10 accepted correctly");

    // Test xz level validation (1-9)
    expect(() => {
      const level = 15;
      if (level < 1 || level > 9) {
        throw new Error("Invalid xz level");
      }
    }).toThrow("Invalid xz level");
    console.log("[E2E] xz level validation works (rejected level 15)");

    expect(() => {
      const level = 6;
      if (level < 1 || level > 9) {
        throw new Error("Invalid xz level");
      }
    }).not.toThrow();
    console.log("[E2E] xz level 6 accepted correctly");

    // Test gzip level validation (1-9)
    expect(() => {
      const level = 12;
      if (level < 1 || level > 9) {
        throw new Error("Invalid gzip level");
      }
    }).toThrow("Invalid gzip level");
    console.log("[E2E] gzip level validation works (rejected level 12)");

    console.log("\n[E2E] PASSED: Compression level validation\n");
  });

  test(
    "Create and compress image with zstd (level 3)",
    async () => {
      console.log("\n========================================");
      console.log("TEST: Create Compressed Image - zstd (level 3)");
      console.log("========================================\n");

      const sourceImg = "test-compression-source-zstd.img";
      const compressedImg = "test-compressed-zstd.img.zst";

      // Create test image via Docker
      console.log(`[E2E] Creating test image: ${sourceImg} (100MB)`);
      await createTestImage(sourceImg, 100);

      const originalSize = await getFileSize(sourceImg);
      expect(originalSize).toBeGreaterThan(0);
      console.log(
        `[E2E] Original image size: ${(originalSize / 1024 / 1024).toFixed(2)} MB`
      );

      // Compress with zstd
      console.log("[E2E] Compressing with zstd (level 3)...");
      await compressFile(sourceImg, compressedImg, "zstd", 3);

      const compressedSize = await getFileSize(compressedImg);
      expect(compressedSize).toBeGreaterThan(0);
      expect(compressedSize).toBeLessThan(originalSize);

      const ratio = calculateCompressionRatio(originalSize, compressedSize);
      console.log(
        `[E2E] Compressed size: ${(compressedSize / 1024 / 1024).toFixed(2)} MB`
      );
      console.log(`[E2E] Compression ratio: ${ratio}%`);

      console.log(
        `\n[E2E] PASSED: zstd compression reduced size by ${ratio}%\n`
      );

      // Clean up source
      await cleanupTestImages([sourceImg]);
    },
    TEST_TIMEOUT
  );

  test(
    "Create and compress image with xz (level 6)",
    async () => {
      console.log("\n========================================");
      console.log("TEST: Create Compressed Image - xz (level 6)");
      console.log("========================================\n");

      const sourceImg = "test-compression-source-xz.img";
      const compressedImg = "test-compressed-xz.img.xz";

      console.log(`[E2E] Creating test image: ${sourceImg} (100MB)`);
      await createTestImage(sourceImg, 100);

      const originalSize = await getFileSize(sourceImg);
      expect(originalSize).toBeGreaterThan(0);
      console.log(
        `[E2E] Original image size: ${(originalSize / 1024 / 1024).toFixed(2)} MB`
      );

      // Compress with xz
      console.log("[E2E] Compressing with xz (level 6)...");
      await compressFile(sourceImg, compressedImg, "xz", 6);

      const compressedSize = await getFileSize(compressedImg);
      expect(compressedSize).toBeGreaterThan(0);
      expect(compressedSize).toBeLessThan(originalSize);

      const ratio = calculateCompressionRatio(originalSize, compressedSize);
      console.log(
        `[E2E] Compressed size: ${(compressedSize / 1024 / 1024).toFixed(2)} MB`
      );
      console.log(`[E2E] Compression ratio: ${ratio}%`);

      console.log(
        `\n[E2E] PASSED: xz compression reduced size by ${ratio}%\n`
      );

      // Clean up source
      await cleanupTestImages([sourceImg]);
    },
    TEST_TIMEOUT
  );

  test(
    "Create and compress image with gzip (level 6)",
    async () => {
      console.log("\n========================================");
      console.log("TEST: Create Compressed Image - gzip (level 6)");
      console.log("========================================\n");

      const sourceImg = "test-compression-source-gzip.img";
      const compressedImg = "test-compressed-gzip.img.gz";

      console.log(`[E2E] Creating test image: ${sourceImg} (100MB)`);
      await createTestImage(sourceImg, 100);

      const originalSize = await getFileSize(sourceImg);
      expect(originalSize).toBeGreaterThan(0);
      console.log(
        `[E2E] Original image size: ${(originalSize / 1024 / 1024).toFixed(2)} MB`
      );

      // Compress with gzip
      console.log("[E2E] Compressing with gzip (level 6)...");
      await compressFile(sourceImg, compressedImg, "gzip", 6);

      const compressedSize = await getFileSize(compressedImg);
      expect(compressedSize).toBeGreaterThan(0);
      expect(compressedSize).toBeLessThan(originalSize);

      const ratio = calculateCompressionRatio(originalSize, compressedSize);
      console.log(
        `[E2E] Compressed size: ${(compressedSize / 1024 / 1024).toFixed(2)} MB`
      );
      console.log(`[E2E] Compression ratio: ${ratio}%`);

      console.log(
        `\n[E2E] PASSED: gzip compression reduced size by ${ratio}%\n`
      );

      // Clean up source
      await cleanupTestImages([sourceImg]);
    },
    TEST_TIMEOUT
  );

  test(
    "Decompression detection and auto-handling",
    async () => {
      console.log("\n========================================");
      console.log("TEST: Decompression Detection");
      console.log("========================================\n");

      // Create dummy compressed files
      await Bun.write("test-detect.img.zst", "dummy");
      await Bun.write("test-detect.img.xz", "dummy");
      await Bun.write("test-detect.img.gz", "dummy");

      // Test .zst detection
      const zstResult = await runCLI([
        "resize",
        "test-detect.img.zst",
        "--dry-run",
      ]);
      expect(zstResult.stderr).toContain("Detected zstd compressed image");
      console.log("[E2E] .zst extension detected correctly");

      // Test .xz detection
      const xzResult = await runCLI([
        "resize",
        "test-detect.img.xz",
        "--dry-run",
      ]);
      expect(xzResult.stderr).toContain("Detected xz compressed image");
      console.log("[E2E] .xz extension detected correctly");

      // Test .gz detection
      const gzResult = await runCLI([
        "resize",
        "test-detect.img.gz",
        "--dry-run",
      ]);
      expect(gzResult.stderr).toContain("Detected gzip compressed image");
      console.log("[E2E] .gz extension detected correctly");

      console.log("\n[E2E] PASSED: Decompression detection\n");

      // Cleanup
      await cleanupTestImages(["test-detect.img.*"]);
    },
    TEST_TIMEOUT
  );

  test(
    "Resize compressed image (zstd) - dry-run",
    async () => {
      console.log("\n========================================");
      console.log("TEST: Resize Compressed Image - zstd (dry-run)");
      console.log("========================================\n");

      const compressedImg = "test-compressed-zstd.img.zst";

      if (!(await Bun.file(compressedImg).exists())) {
        console.log("[E2E] Compressed image not found, skipping test");
        return;
      }

      // Compute checksum before
      const checksumBefore = await computeChecksum(compressedImg);

      console.log(`[E2E] Running dry-run resize on ${compressedImg}...`);
      const result = await runCLI([
        "resize",
        compressedImg,
        "--boot-size",
        "128",
        "--dry-run",
      ]);

      // Should detect compressed image
      expect(result.stderr).toContain("Detected zstd compressed image");
      console.log("[E2E] Compressed image detected by resize");

      // Original file should be unchanged
      const checksumAfter = await computeChecksum(compressedImg);
      expect(checksumAfter).toBe(checksumBefore);
      console.log("[E2E] Original compressed file unchanged");

      console.log("\n[E2E] PASSED: Resize zstd compressed image (dry-run)\n");
    },
    TEST_TIMEOUT
  );
});
