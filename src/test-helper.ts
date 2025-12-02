/**
 * Test helper that runs inside Docker container to create test images
 * and validate resize operations. Replaces test-create-and-resize.sh
 */

import { existsSync, unlinkSync, readdirSync } from "node:fs";
import { join } from "node:path";

interface TestConfig {
  imageFile: string;
  bootSizeMB: number;
  initialBootMB: number;
  initialImageMB: number;
  targetImageMB?: number;
  freeTailMB: number;
  verbose: boolean;
  snapshot: boolean;
}

function log(message: string): void {
  console.log(`[TEST] ${message}`);
}

async function run(cmd: string[], options: { allowFail?: boolean } = {}): Promise<{ success: boolean; output: string }> {
  try {
    const proc = Bun.spawn(cmd, {
      stdout: "pipe",
      stderr: "pipe",
    });

    const stdout = await new Response(proc.stdout).text();
    const stderr = await new Response(proc.stderr).text();
    const exitCode = await proc.exited;

    const result = {
      success: exitCode === 0,
      output: stdout + (stderr ? "\n" + stderr : ""),
    };

    if (!result.success && !options.allowFail) {
      throw new Error(`Command failed (${exitCode}): ${cmd.join(" ")}\n${result.output}`);
    }

    return result;
  } catch (error: unknown) {
    if (!options.allowFail) {
      throw error;
    }
    return { success: false, output: error instanceof Error ? error.message : String(error) };
  }
}

function findFilesRecursiveSync(dir: string, files: string[] = []): string[] {
  try {
    const entries = readdirSync(dir, { withFileTypes: true });
    
    for (const entry of entries) {
      const fullPath = join(dir, entry.name);
      
      if (entry.isDirectory()) {
        findFilesRecursiveSync(fullPath, files);
      } else if (entry.isFile()) {
        files.push(fullPath);
      }
    }
  } catch {
    // Skip directories we can't read
  }

  return files;
}

async function createSnapshot(mountPoint: string, outputFile: string): Promise<void> {
  log(`Recording snapshot: ${outputFile}`);
  
  const files = findFilesRecursiveSync(mountPoint);
  
  const checksums: string[] = [];
  for (const file of files) {
    try {
      const fileContent = Bun.file(file);
      const buffer = await fileContent.arrayBuffer();
      const hasher = new Bun.CryptoHasher("sha256");
      hasher.update(new Uint8Array(buffer));
      const checksum = hasher.digest("hex");
      
      const relativePath = file.replace(`${mountPoint}/`, "");
      checksums.push(`${checksum}  ${relativePath}`);
    } catch {
      // Skip files we can't read
    }
  }
  
  checksums.sort();
  await Bun.write(`/work/${outputFile}`, checksums.join("\n") + "\n");
}

async function main(): Promise<void> {
  const config: TestConfig = {
    imageFile: process.env.IMAGE_FILE ?? "test.img",
    bootSizeMB: parseInt(process.env.BOOT_SIZE_MB ?? "256", 10),
    initialBootMB: 64,
    initialImageMB: parseInt(process.env.INITIAL_IMAGE_MB ?? "700", 10),
    targetImageMB: process.env.TARGET_IMAGE_MB
      ? parseInt(process.env.TARGET_IMAGE_MB, 10)
      : undefined,
    freeTailMB: parseInt(process.env.FREE_TAIL_MB ?? "0", 10),
    verbose: process.env.VERBOSE === "1",
    snapshot: process.env.SNAPSHOT === "1",
  };

  const workDir = "/work";
  const imagePath = join(workDir, config.imageFile);

  log(`Configuration: ${JSON.stringify(config, null, 2)}`);

  try {
    if (existsSync(imagePath)) {
      log(`Removing existing image ${config.imageFile}`);
      unlinkSync(imagePath);
    }
  } catch {
    // Ignore if file doesn't exist
  }

  log(`Creating blank image ${config.initialImageMB}MB...`);
  await run([
    "dd",
    "if=/dev/zero",
    `of=${imagePath}`,
    "bs=1M",
    `count=${config.initialImageMB}`,
    "status=none",
  ]);

  const loopResult = await run(["losetup", "-f", "--show", imagePath]);
  if (!loopResult.success) {
    throw new Error(`Failed to attach loop device: ${loopResult.output}`);
  }
  const loopDevice = loopResult.output.trim();
  log(`Loop device (initial): ${loopDevice}`);

  try {
    const sectorsTotal = (config.initialImageMB * 1024 * 1024) / 512;
    const bootSizeSectors = (config.initialBootMB * 1024 * 1024) / 512;
    const freeTailSectors = (config.freeTailMB * 1024 * 1024) / 512;
    const bootStart = 8192;
    const bootEnd = bootStart + bootSizeSectors - 1;
    const rootStart = bootEnd + 1;
    const rootEnd = sectorsTotal - 1 - freeTailSectors;
    const rootSizeSectors = rootEnd - rootStart + 1;

    if (config.freeTailMB > 0) {
      log(
        `Writing initial partition table (boot ${config.initialBootMB}MB, root rest, free tail ${config.freeTailMB}MB)...`
      );
    } else {
      log(
        `Writing initial partition table (boot ${config.initialBootMB}MB, root rest)...`
      );
    }

    const sfdiskLayout = `label: dos
unit: sectors

${loopDevice}p1 : start=${bootStart}, size=${bootSizeSectors}, type=c, bootable
${loopDevice}p2 : start=${rootStart}, size=${rootSizeSectors}, type=83
`;

    await Bun.write("/tmp/layout.sfdisk", sfdiskLayout);

    const layoutContent = await Bun.file("/tmp/layout.sfdisk").text();
    const sfdiskProc = Bun.spawn(["sfdisk", loopDevice], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
    });

    sfdiskProc.stdin.write(layoutContent);
    sfdiskProc.stdin.end();
    await sfdiskProc.exited;

    await run(["sync"]);

    await run(["losetup", "-d", loopDevice]);
    const loopResult2 = await run(["losetup", "-f", "--show", "-P", imagePath]);
    const loopDevice2 = loopResult2.output.trim();
    log(`Loop device reattached: ${loopDevice2}`);

    log("Creating kpartx mappings for partitions...");
    await run(["kpartx", "-av", loopDevice2]);
    await Bun.sleep(1000);

    const loopBasename = loopDevice2.split("/").pop() ?? "loop0";
    const bootPart = `/dev/mapper/${loopBasename}p1`;
    const rootPart = `/dev/mapper/${loopBasename}p2`;

    if (!existsSync(bootPart) || !existsSync(rootPart)) {
      log("Partition mapper devices not found; listing /dev/mapper:");
      await run(["ls", "-l", "/dev/mapper"]);
      throw new Error("Partition devices not found");
    }

    log("Formatting boot (FAT32) and root (ext4)...");
    await run(["mkfs.vfat", "-F32", bootPart]);
    await run(["mkfs.ext4", "-F", rootPart]);

    log("Populating boot partition with sample files...");
    await run(["mkdir", "-p", "/mnt/boot"]);
    await run(["mount", bootPart, "/mnt/boot"]);

    try {
      await run(["mkdir", "-p", "/mnt/boot/overlays"]);
      await Bun.write(
        "/mnt/boot/cmdline.txt",
        "console=serial0,115200 console=tty1 root=PARTUUID=12345678-02 rootfstype=ext4 rootwait"
      );
      await Bun.write(
        "/mnt/boot/config.txt",
        "# Test config.txt\ndtparam=audio=on\n"
      );
      await run([
        "dd",
        "if=/dev/urandom",
        "of=/mnt/boot/kernel.img",
        "bs=1M",
        "count=5",
        "status=none",
      ]);
      await run([
        "dd",
        "if=/dev/urandom",
        "of=/mnt/boot/overlays/test.dtbo",
        "bs=1K",
        "count=10",
        "status=none",
      ]);
      await run(["sync"]);

      if (config.snapshot) {
        await createSnapshot("/mnt/boot", "snapshot-boot-pre.txt");
      }
    } finally {
      await run(["umount", "/mnt/boot"]);
    }

    log("Populating root filesystem with sample data...");
    await run(["mkdir", "-p", "/mnt/root"]);
    await run(["mount", rootPart, "/mnt/root"]);

    try {
      await run(["mkdir", "-p", "/mnt/root/var/log", "/mnt/root/usr/lib"]);
      for (let i = 1; i <= 15; i++) {
        await run([
          "dd",
          "if=/dev/urandom",
          `of=/mnt/root/var/log/log.${i}`,
          "bs=10M",
          "count=1",
          "status=none",
        ]);
      }
      await run(["sync"]);

      if (config.snapshot) {
        await createSnapshot("/mnt/root", "snapshot-pre.txt");
      }
    } finally {
      await run(["umount", "/mnt/root"]);
    }

    log("Initial layout:");
    const fdiskResult = await run(["fdisk", "-l", loopDevice2]);
    if (config.verbose) {
      console.log(fdiskResult.output);
    }

    log("Syncing before resize run...");
    await run(["sync"]);
    await Bun.sleep(1000);

    log("Detaching loop device before worker...");
    await run(["kpartx", "-d", loopDevice2]);
    await run(["losetup", "-d", loopDevice2]);

    process.env.IMAGE_FILE = config.imageFile;
    process.env.BOOT_SIZE_MB = config.bootSizeMB.toString();
    process.env.VERBOSE = config.verbose ? "1" : "0";

    if (config.targetImageMB) {
      process.env.IMAGE_SIZE = `${config.targetImageMB}MB`;
      log(
        `Running resize worker: image ${config.initialImageMB}MB→${config.targetImageMB}MB, boot ${config.initialBootMB}MB→${config.bootSizeMB}MB`
      );
    } else {
      log(
        `Running resize worker: boot ${config.initialBootMB}MB→${config.bootSizeMB}MB (no image resize)`
      );
    }

    // Spawn worker with explicit env to ensure IMAGE_SIZE is propagated
    const workerProc = Bun.spawn([
      "bun",
      "/usr/local/bin/resize-worker.js",
    ], {
      env: { ...process.env },
      stdout: "pipe",
      stderr: "pipe",
    });
    const workerStdout = await new Response(workerProc.stdout).text();
    const workerStderr = await new Response(workerProc.stderr).text();
    const workerExit = await workerProc.exited;
    const workerResult = { success: workerExit === 0, output: workerStdout + (workerStderr ? "\n" + workerStderr : "") };
    if (!workerResult.success) {
      log("Resize script failed");
      console.error(workerResult.output);
      process.exit(1);
    }
    if (config.verbose) {
      log("Worker output (verbose):\n" + workerResult.output);
    }

    log("Re-attaching image for post-resize snapshot...");
    const postLoopResult = await run([
      "losetup",
      "-f",
      "--show",
      "-P",
      imagePath,
    ]);
    const postLoop = postLoopResult.output.trim();
    log(`Post loop device: ${postLoop}`);

    await run(["kpartx", "-av", postLoop]);
    await Bun.sleep(1000);

    const postLoopBasename = postLoop.split("/").pop() ?? "loop0";
    const postRoot = `/dev/mapper/${postLoopBasename}p2`;
    const postBoot = `/dev/mapper/${postLoopBasename}p1`;

    const postFdiskResult = await run(["fdisk", "-l", postLoop]);
    if (config.verbose) {
      console.log(postFdiskResult.output);
    }
    await run(["blkid", postBoot, postRoot]);

    if (config.snapshot) {
      if (existsSync(postRoot)) {
        log("Recording post-resize root snapshot (sha256 list)");
        await run(["mkdir", "-p", "/mnt/root"]);
        await run(["mount", postRoot, "/mnt/root"]);
        await createSnapshot("/mnt/root", "snapshot-post.txt");
        await run(["umount", "/mnt/root"]);
      } else {
        log("Post root device not found; skipping post snapshot");
      }

      if (existsSync(postBoot)) {
        log("Recording post-resize boot snapshot (sha256 list)");
        await run(["mkdir", "-p", "/mnt/boot"]);
        await run(["mount", postBoot, "/mnt/boot"]);
        await createSnapshot("/mnt/boot", "snapshot-boot-post.txt");
        await run(["umount", "/mnt/boot"]);
      } else {
        log("Post boot device not found; skipping boot post snapshot");
      }
    }

    log("Cleaning post snapshot loop/mappings...");
    await run(["kpartx", "-d", postLoop]);
    await run(["losetup", "-d", postLoop]);

    log("All done.");
  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    const errorStack = error instanceof Error ? error.stack : undefined;
    log(`Error: ${errorMessage}`);
    if (errorStack) {
      console.error(errorStack);
    }
    await run(["kpartx", "-d", loopDevice], { allowFail: true });
    await run(["losetup", "-d", loopDevice], { allowFail: true });
    process.exit(1);
  }
}

main();
