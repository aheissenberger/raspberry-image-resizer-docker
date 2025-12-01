/**
 * E2E test helpers for Docker-based integration tests
 */

import { spawn } from "bun";
import { unlinkSync } from "fs";

export interface TestImageConfig {
  filename: string;
  initialSizeMB: number;
  targetSizeMB?: number;
  bootSizeMB: number;
  freeTailMB?: number;
  verbose?: boolean;
  snapshot?: boolean;
}

export interface SnapshotFiles {
  rootPre: string;
  rootPost: string;
  bootPre: string;
  bootPost: string;
}

export interface TestResult {
  success: boolean;
  output: string;
  error?: string;
  snapshotValid?: boolean;
}

/**
 * Build the Docker image for testing
 */
export async function buildDockerImage(
  imageName: string,
  noCache: boolean = false
): Promise<void> {
  const args = ["build", "-t", imageName, "."];
  if (noCache) {
    args.splice(1, 0, "--no-cache");
  }

  const proc = spawn({
    cmd: ["docker", ...args],
    cwd: process.cwd(),
    stdout: "inherit",
    stderr: "inherit",
  });

  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(`Docker build failed with exit code ${exitCode}`);
  }
}

/**
 * Run Docker container with test-create-and-resize.sh
 */
export async function runDockerTest(
  imageName: string,
  config: TestImageConfig
): Promise<TestResult> {
  const env: Record<string, string> = {
    IMAGE_FILE: config.filename,
    BOOT_SIZE_MB: config.bootSizeMB.toString(),
    INITIAL_IMAGE_MB: config.initialSizeMB.toString(),
    VERBOSE: config.verbose ? "1" : "0",
    SNAPSHOT: config.snapshot ? "1" : "0",
  };

  if (config.targetSizeMB) {
    env.TARGET_IMAGE_MB = config.targetSizeMB.toString();
  }

  if (config.freeTailMB !== undefined) {
    env.FREE_TAIL_MB = config.freeTailMB.toString();
  }

  const envArgs = Object.entries(env).flatMap(([key, value]) => [
    "-e",
    `${key}=${value}`,
  ]);

  const args = [
    "run",
    "--rm",
    "--privileged",
    "--entrypoint",
    "/root/.bun/bin/bun",
    "-v",
    `${process.cwd()}:/work`,
    ...envArgs,
    imageName,
    "/usr/local/bin/test-helper.js",
  ];

  const proc = spawn({
    cmd: ["docker", ...args],
    cwd: process.cwd(),
    stdout: "pipe",
    stderr: "pipe",
  });

  // Read streams using Bun's Response wrapper
  const exitCode = await proc.exited;
  const stdoutText = await new Response(proc.stdout).text();
  const stderrText = await new Response(proc.stderr).text();

  const output = stdoutText;
  const error = stderrText;

  if (config.verbose) {
    if (output) process.stdout.write(output);
    if (error) process.stderr.write(error);
  }

  return {
    success: exitCode === 0,
    output,
    error: error.length > 0 ? error : undefined,
  };
}

/**
 * Compare snapshot files
 */
export async function compareSnapshots(
  preFile: string,
  postFile: string
): Promise<boolean> {
  const preExists = await Bun.file(preFile).exists();
  const postExists = await Bun.file(postFile).exists();
  if (!preExists || !postExists) {
    return false;
  }

  const preContent = await Bun.file(preFile).text();
  const postContent = await Bun.file(postFile).text();

  return preContent === postContent;
}

/**
 * Check all snapshot files and compare
 */
export async function validateSnapshots(
  snapshots: SnapshotFiles
): Promise<{ rootValid: boolean; bootValid: boolean }> {
  const rootValid = await compareSnapshots(
    snapshots.rootPre,
    snapshots.rootPost
  );
  const bootValid = await compareSnapshots(
    snapshots.bootPre,
    snapshots.bootPost
  );

  return { rootValid, bootValid };
}

/**
 * Clean up snapshot files
 */
export async function cleanupSnapshots(snapshots: SnapshotFiles): Promise<void> {
  const files = [
    snapshots.rootPre,
    snapshots.rootPost,
    snapshots.bootPre,
    snapshots.bootPost,
  ];

  for (const file of files) {
    if (await Bun.file(file).exists()) {
      unlinkSync(file);
    }
  }
}

/**
 * Clean up test image files
 */
export async function cleanupTestImages(patterns: string[]): Promise<void> {
  for (const pattern of patterns) {
    const files = Array.from(
      new Bun.Glob(pattern).scanSync({ cwd: process.cwd(), absolute: true })
    );
    for (const file of files) {
      if (await Bun.file(file).exists()) {
        unlinkSync(file);
      }
    }
  }
}

/**
 * Create a test image using the CLI tool
 */
export async function createTestImage(
  filename: string,
  sizeMB: number
): Promise<void> {
  // Create a simple empty image file
  const proc = spawn({
    cmd: ["dd", "if=/dev/zero", `of=${filename}`, "bs=1M", `count=${sizeMB}`],
    cwd: process.cwd(),
    stdout: "pipe",
    stderr: "pipe",
  });

  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(`Failed to create test image ${filename}`);
  }
}

/**
 * Compress a file using specified algorithm
 */
export async function compressFile(
  inputFile: string,
  outputFile: string,
  algorithm: "zstd" | "xz" | "gzip",
  level: number
): Promise<void> {
  let cmd: string[];

  switch (algorithm) {
    case "zstd":
      cmd = ["zstd", `-${level}`, "-T0", inputFile, "-o", outputFile];
      break;
    case "xz":
      cmd = ["xz", `-${level}`, "-T0", "-c", inputFile];
      break;
    case "gzip":
      cmd = ["gzip", `-${level}`, "-c", inputFile];
      break;
  }

  const proc = spawn({
    cmd,
    cwd: process.cwd(),
    stdout: algorithm === "zstd" ? "inherit" : "pipe",
    stderr: "pipe",
  });

  // For xz and gzip, redirect stdout to output file
  if (algorithm !== "zstd") {
    const stdoutText = await new Response(proc.stdout).text();
    await Bun.write(outputFile, stdoutText);
  }

  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(
      `Failed to compress ${inputFile} with ${algorithm} (exit code ${exitCode})`
    );
  }
}

/**
 * Get file size in bytes
 */
export async function getFileSize(filepath: string): Promise<number> {
  const file = Bun.file(filepath);
  if (!(await file.exists())) {
    return -1;
  }
  return file.size;
}

/**
 * Calculate compression ratio
 */
export function calculateCompressionRatio(
  originalSize: number,
  compressedSize: number
): number {
  return Math.round((100 * (originalSize - compressedSize)) / originalSize);
}

/**
 * Compute MD5 checksum of a file
 */
export async function computeChecksum(filepath: string): Promise<string> {
  const file = Bun.file(filepath);
  if (!(await file.exists())) {
    return "FILE_NOT_FOUND";
  }

  const hasher = new Bun.CryptoHasher("md5");
  hasher.update(await file.arrayBuffer());
  return hasher.digest("hex");
}

/**
 * Wait for Docker container to be ready
 */
export async function waitForDocker(): Promise<boolean> {
  const proc = spawn({
    cmd: ["docker", "info"],
    stdout: "pipe",
    stderr: "pipe",
  });

  const exitCode = await proc.exited;
  return exitCode === 0;
}

/**
 * Check if Docker image exists
 */
export async function dockerImageExists(imageName: string): Promise<boolean> {
  const proc = spawn({
    cmd: ["docker", "image", "inspect", imageName],
    stdout: "pipe",
    stderr: "pipe",
  });

  const exitCode = await proc.exited;
  return exitCode === 0;
}
