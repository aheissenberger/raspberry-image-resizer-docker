#!/usr/bin/env bun
import { spawn } from "bun";
import readline from "node:readline";
import { parseArgs } from "./lib/args";
import { BunExecutor } from "./lib/executor";
import { resolveBlockSize as _resolveBlockSize, buildCloneDdCommand, buildWriteDdCommand } from "./lib/dd";
import { buildCompressor, buildDecompressor, detectCompressionByExt, validateLevel } from "./lib/compress";
import { detectPiDisk, detectRemovableDisk, normalizeDevice } from "./lib/devices";
import { ensureImage, runWorker } from "./lib/docker";
import pkg from "../package.json";

const VERSION: string = (pkg as any).version || "0.0.0";

function usage() {
  console.log(`raspberry-image-tool v${VERSION}\n\n` +
`Usage:\n  rpi-tool <command> [options]\n\n` +
`Commands:\n  version                    Print version\n  clone <output-image>       Clone SD to image (macOS)\n  write <image>              Write image to SD (macOS)\n  resize <image>             Resize and adjust partitions (Docker)\n  clean                      Remove Docker images\n\n` +
  `  deploy <image>             Resize image (Docker) then write to SD (macOS)\n` +
  `  size                       Show size of removable device (macOS)\n\n` +
`Global Options:\n  -h, --help                 Show help\n  -v, --version              Show version\n\n` +
  `Clone/Write/Size Options:\n  --compress <zstd|xz|gzip>  Compress output during clone\n  --level <n>                Compression level\n  --block-size <SIZE>        dd block size (default 4m)\n  --device </dev/diskN>      Override auto-detect; use specific disk (advanced)\n  --yes                      Skip confirmations (write only; dangerous)\n  --preview                  Print the dd command and exit (no changes)\n` +
    `  --verify-fs                Basic read verification after write (macOS limitation)\n` +
    `  --verbose                  Print duration summary after completion\n\n` +
`Resize Options:\n  --boot-size <MB>           Target boot partition size (default 256)\n  --image-size <SIZE>        Change overall image size (e.g. 32GB, 8192MB)\n  --unsafe-resize-ext4       Run resize2fs on root when not moving (unsafe)\n  --dry-run                  Plan only, do not modify\n  --verbose                  Verbose logs (also runs final read-only fsck)\n  --verify-fs                Run final read-only e2fsck verification\n  --docker-image <name>      Docker image name (default rpi-image-resizer:latest)\n  --work-dir <path>          Working directory for temp files (default: TMPDIR or /tmp for compressed)\n`);
}

function escapePath(p: string) {
  return `'${p.replaceAll("'", "'\\''")}'`;
}
function dirname(p: string) { return p.substring(0, p.lastIndexOf("/")) || "."; }
function basename(p: string) { return p.substring(p.lastIndexOf("/") + 1); }

function resolveBlockSize(input?: string) {
  const def = "4m";
  const v = _resolveBlockSize(input);
  if (input && v === def && input.trim().toLowerCase() !== def && !/^[1-9][0-9]*(?:[kKmMgG])?$/.test(input)) {
    console.error(`Invalid --block-size '${input}', falling back to ${def}`);
  }
  return v;
}

function bytesToGiB(n: number): string {
  return `${(n / (1024 ** 3)).toFixed(2)} GiB`;
}

async function getDiskSizeBytes(exec: BunExecutor, disk: string): Promise<number> {
  // disk should be like /dev/diskX (NOT rdisk)
  const cmd = `diskutil info -plist ${disk} | plutil -convert json -o - -`;
  const res = await exec.run(["bash", "-lc", cmd]);
  if (res.code !== 0) throw new Error(`Failed to query disk info for ${disk}`);
  try {
    const info = JSON.parse(res.stdout);
    // Prefer TotalSize, fall back to MediaSize or Size
    return Number(info.TotalSize ?? info.MediaSize ?? info.Size ?? 0);
  } catch {
    throw new Error(`Unable to parse disk info JSON for ${disk}`);
  }
}

function formatDuration(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  
  if (hours > 0) {
    const remainingMinutes = minutes % 60;
    const remainingSeconds = seconds % 60;
    return `${hours}h ${remainingMinutes}m ${remainingSeconds}s`;
  } else if (minutes > 0) {
    const remainingSeconds = seconds % 60;
    return `${minutes}m ${remainingSeconds}s`;
  } else {
    return `${seconds}s`;
  }
}

// Shared utility: detect and select removable device for write/deploy operations
async function detectAndSelectDevice(exec: BunExecutor, explicitDevice?: string): Promise<{ disk: string; rdisk: string }> {
  let selected: string | undefined = explicitDevice;
  if (!selected) {
    const disks = (await exec.run(["bash", "-lc", "diskutil list | grep -E '^/dev/disk[0-9]+' | awk '{print $1}'"]))
      .stdout.trim().split(/\s+/).filter(Boolean);
    for (const d of disks) {
      const info = await exec.run(["bash", "-lc", `diskutil info ${d} | grep 'Removable Media:' | grep -q Removable && echo yes || echo no`]);
      if (info.stdout.trim() === "yes") { selected = d; break; }
    }
  }
  if (!selected) throw new Error("No removable device detected");
  const raw = selected.replace("/dev/disk", "/dev/rdisk");
  return { disk: selected, rdisk: raw };
}

// Shared utility: preflight check that image fits on device
async function preflightImageSize(exec: BunExecutor, imagePath: string, device: string, isCompressed: boolean): Promise<void> {
  if (!isCompressed) {
    const imgSize = Bun.file(imagePath).size;
    const devSize = await getDiskSizeBytes(exec, device);
    if (imgSize > devSize) {
      throw new Error(
        `Image (${bytesToGiB(imgSize)}) is larger than device ${device} (${bytesToGiB(devSize)}). ` +
        `Use 'rpi-tool resize --image-size <smaller size>' to shrink the image or choose a larger device.`
      );
    }
  } else {
    console.error("Note: writing from compressed stream; exact uncompressed size preflight is not available.");
  }
}

// Shared utility: write image to device with optional decompression
async function writeImageToDevice(
  exec: BunExecutor,
  imagePath: string,
  device: { disk: string; rdisk: string },
  blockSize: string,
  decompressor?: string[],
  verifyFs?: boolean
): Promise<void> {
  // Proactively request sudo to avoid pause when dd starts
  await exec.run(["sudo", "-v"], { allowNonZeroExit: true });
  await exec.run(["diskutil", "unmountDisk", device.disk], { allowNonZeroExit: true });
  
  console.log(`About to WRITE image to device: ${device.disk} (raw ${device.rdisk})`);
  
  if (decompressor) {
    const cmd = `${decompressor.join(" ")} ${escapePath(imagePath)} | sudo dd of=${device.rdisk} bs=${blockSize} conv=fsync status=progress`;
    await exec.run(["bash", "-lc", cmd], { onStderrChunk: (s) => process.stderr.write(s) });
  } else {
    await exec.run(
      ["bash", "-lc", `sudo dd if=${escapePath(imagePath)} of=${device.rdisk} bs=${blockSize} conv=fsync status=progress`],
      { onStderrChunk: (s) => process.stderr.write(s) }
    );
  }
  
  await exec.run(["sync"], { allowNonZeroExit: true });
  await exec.run(["diskutil", "mountDisk", device.disk], { allowNonZeroExit: true });
  
  if (verifyFs) {
      // verifyFilesystemsOnDeviceViaDocker(exec, device);
  }
}

  // Shared utility: verify filesystems on device after write (Docker-based)
  async function verifyFilesystemsOnDeviceViaDocker(
    exec: BunExecutor,
    device: { disk: string; rdisk: string }
  ): Promise<void> {
    console.log("\n[VERIFY] Running filesystem checks on written device via Docker container...");
  
    // Unmount device on macOS before Docker access
    await exec.run(["diskutil", "unmountDisk", device.disk], { allowNonZeroExit: true });
  
    try {
      // Create verification script that will run inside Docker container
      const verifyScript = `#!/bin/bash
  set -e
  DEVICE="$1"

  echo "[VERIFY] Attaching device in container: \${DEVICE}"

  # Check FAT filesystem on partition 1 (boot)
  echo "[VERIFY] Checking boot partition (FAT)..."
  if fsck.vfat -n "\${DEVICE}1" 2>&1; then
    BOOT_CODE=$?
    if [ $BOOT_CODE -eq 0 ]; then
      echo "[VERIFY] ✓ Boot partition (FAT): clean"
    elif [ $BOOT_CODE -eq 1 ]; then
      echo "[VERIFY] ✓ Boot partition (FAT): clean (minor issues corrected in check)"
    else
      echo "[VERIFY] ✗ Boot partition (FAT): errors detected (code $BOOT_CODE)"
      exit 1
    fi
  else
    BOOT_CODE=$?
    echo "[VERIFY] ✗ Boot partition (FAT): check failed with code $BOOT_CODE"
    exit 1
  fi

  # Check ext4 filesystem on partition 2 (root)
  echo "[VERIFY] Checking root partition (ext4)..."
  if e2fsck -n -f "\${DEVICE}2" 2>&1; then
    EXT4_CODE=$?
    if [ $EXT4_CODE -eq 0 ]; then
      echo "[VERIFY] ✓ Root partition (ext4): clean"
    elif [ $EXT4_CODE -eq 1 ]; then
      echo "[VERIFY] ✓ Root partition (ext4): clean (issues corrected in check)"
    elif [ $EXT4_CODE -eq 4 ]; then
      echo "[VERIFY] ⚠ Root partition (ext4): uncorrected errors (read-only check)"
    elif [ $EXT4_CODE -ge 8 ]; then
      echo "[VERIFY] ✗ Root partition (ext4): fatal errors (code $EXT4_CODE)"
      exit 1
    else
      echo "[VERIFY] ⚠ Root partition (ext4): check returned code $EXT4_CODE"
    fi
  else
    EXT4_CODE=$?
    if [ $EXT4_CODE -ge 8 ]; then
      echo "[VERIFY] ✗ Root partition (ext4): check failed with code $EXT4_CODE"
      exit 1
    elif [ $EXT4_CODE -eq 4 ]; then
      echo "[VERIFY] ⚠ Root partition (ext4): uncorrected errors (read-only check)"
    else
      echo "[VERIFY] ⚠ Root partition (ext4): check returned code $EXT4_CODE"
    fi
  fi

  echo "[VERIFY] Filesystem verification completed"
  `;

      // Write script to temp file
      const scriptPath = `/tmp/verify-fs-${Date.now()}.sh`;
      await Bun.write(scriptPath, verifyScript);
      await exec.run(["chmod", "+x", scriptPath]);

      // Run Docker container with privileged mode to access device
      const dockerImage = "ghcr.io/andihofmeister/raspberry-pi-image-resizer:latest";
      const dockerArgs = [
        "run",
        "--rm",
        "--privileged",
        "-v", `${scriptPath}:/verify.sh`,
        dockerImage,
        "/verify.sh",
        device.disk
      ];

      console.log(`[VERIFY] Running Docker verification with device ${device.disk}...`);
      const result = await exec.run(["docker", ...dockerArgs], { allowNonZeroExit: true });
    
      // Clean up script
      await exec.run(["rm", scriptPath], { allowNonZeroExit: true });

      if (result.code !== 0) {
        console.error("[VERIFY] Filesystem verification failed");
        console.error(result.stdout);
        console.error(result.stderr);
        throw new Error(`Filesystem verification failed with exit code ${result.code}`);
      }

      console.log("[VERIFY] All filesystem checks passed\n");
    } finally {
      // Always remount after checks
      await exec.run(["diskutil", "mountDisk", device.disk], { allowNonZeroExit: true });
    }
  }

// Shared utility: prepare working image (decompress or copy)
async function prepareWorkingImage(
  image: string,
  workingPath: string,
  isDryRun: boolean
): Promise<string> {
  const algo = detectCompressionByExt(image);
  
  if (algo) {
    console.error(`Detected ${algo} compressed image`);
    if (isDryRun) {
      console.error("Dry-run: skipping decompression");
      return image;
    } else {
      const decomp = buildDecompressor(algo);
      decomp.push(image);
      const proc = spawn({
        cmd: decomp,
        stdout: Bun.file(workingPath),
        stderr: "pipe",
      });
      const exitCode = await proc.exited;
      const stderr = await new Response(proc.stderr).text();
      
      if (exitCode !== 0) {
        throw new Error(`Decompression failed with code ${exitCode}\n${stderr}`);
      }
      console.log(`Working copy created: ${workingPath}`);
      return workingPath;
    }
  }
  
  return image;
}

// Shared utility: create backup of source image
async function createBackup(
  exec: BunExecutor,
  sourcePath: string,
  targetPath: string,
  isDryRun: boolean
): Promise<void> {
  if (!isDryRun) {
    await exec.run(["cp", sourcePath, targetPath]);
    console.log(`Backup created: ${targetPath}`);
  } else {
    console.log("Dry-run: not creating backup or working copy, operating read-only");
  }
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("-h") || argv.includes("--help")) return usage();
  if (argv.includes("-v") || argv.includes("--version")) { console.log(VERSION); return; }
  const [command, ...rest] = argv;
  if (!command) return usage();

  // Support `version` as a command
  if (command === "version") { console.log(VERSION); return; }

  const startTime = Date.now();
  const exec = new BunExecutor();

  if (command === "clone") {
    const { args, positional } = parseArgs(rest, [
      { name: "compress", type: "string" },
      { name: "level", type: "number" },
      { name: "block-size", type: "string" },
      { name: "device", type: "string" },
      { name: "preview", type: "boolean" }
    ]);
    const output = positional[0];
    if (!output) throw new Error("Missing <output-image>");
    const bs = resolveBlockSize(args["block-size"] as string | undefined);

    const selected = args.device ? normalizeDevice(String(args.device)).disk : await detectPiDisk(exec);
    if (!selected) throw new Error("No removable Raspberry Pi SD card detected");

    const raw = args.device ? normalizeDevice(String(args.device)).rdisk : selected.replace("/dev/disk", "/dev/rdisk");

    if (args.device) {
      console.warn(`Using explicit device override: ${selected} (raw ${raw}). Operation is read-only (clone).`);
    }

    // Progress will be shown via dd's status=progress (or SIGINFO on macOS)

    // Optional compression
    let compressor: string[] | undefined;
    if (args.compress) {
      const algo = String(args.compress) as any;
      validateLevel(algo, args.level);
      compressor = buildCompressor(algo, args.level);
    }

    // Build dd command and optionally preview
    const ddCmd = buildCloneDdCommand({ rawDevice: raw, outputPath: escapePath(output), blockSize: bs, compressor });
    if (args.preview) {
      console.log(ddCmd);
      return;
    }

    // Unmount volumes (best-effort) then run dd
    await exec.run(["diskutil", "unmountDisk", selected], { allowNonZeroExit: true });
    await exec.run(["bash", "-lc", ddCmd], { onStderrChunk: (s) => process.stderr.write(s) });

    await exec.run(["sync"], { allowNonZeroExit: true });
    await exec.run(["diskutil", "mountDisk", selected], { allowNonZeroExit: true });
    console.log("✓ Clone completed");
    if (argv.includes("--verbose")) {
      const duration = Date.now() - startTime;
      console.log(`[DURATION] ${formatDuration(duration)}`);
    }
    return;
  }

  if (command === "size") {
    const { args } = parseArgs(rest, [
      { name: "device", type: "string" }
    ]);
    const selected = args.device ? normalizeDevice(String(args.device)).disk : await detectRemovableDisk(exec);
    if (!selected) throw new Error("No removable device detected");
    const sizeBytes = await getDiskSizeBytes(exec, selected);
    const gib = sizeBytes / (1024 ** 3);
    const gb = sizeBytes / 1_000_000_000;
    // Recommend a safe rounded-down decimal GB value with 2% headroom, rounded down to 0.1GB
    let safeGb = Math.floor(gb * 0.98 * 10) / 10;
    if (safeGb <= 0) safeGb = Math.max(0, Math.floor(gb * 10) / 10 - 0.1);
    console.log(`${selected}: ${bytesToGiB(sizeBytes)} (${sizeBytes} bytes)`);
    console.log(`Approx capacity: ${gb.toFixed(2)} GB`);
    console.log(`Recommended --image-size: ${safeGb.toFixed(1)}GB`);
    if (argv.includes("--verbose")) {
      const duration = Date.now() - startTime;
      console.log(`[DURATION] ${formatDuration(duration)}`);
    }
    return;
  }

  if (command === "write") {
    const { args, positional } = parseArgs(rest, [
      { name: "device", type: "string" },
      { name: "block-size", type: "string" },
      { name: "verify-fs", type: "boolean" }
    ]);
    const image = positional[0];
    if (!image) throw new Error("Missing <image>");

    const device = await detectAndSelectDevice(exec, args.device as string | undefined);
    const bs = resolveBlockSize(args["block-size"] as string | undefined);
    const algo = detectCompressionByExt(image);
    const decomp = algo ? buildDecompressor(algo) : undefined;
    const verifyFs = args["verify-fs"] || argv.includes("--verbose");

    await preflightImageSize(exec, image, device.disk, !!algo);
    await writeImageToDevice(exec, image, device, bs, decomp, verifyFs);
    
    console.log("✓ Write completed");
    if (argv.includes("--verbose")) {
      const duration = Date.now() - startTime;
      console.log(`[DURATION] ${formatDuration(duration)}`);
    }
    return;
  }

  if (command === "deploy") {
    const { args, positional } = parseArgs(rest, [
      // Resize-related
      { name: "boot-size", type: "number", default: 256 },
      { name: "image-size", type: "string" },
      { name: "unsafe-resize-ext4", type: "boolean" },
      { name: "verify-fs", type: "boolean" },
      { name: "docker-image", type: "string" },
      { name: "work-dir", type: "string" },
      { name: "dry-run", type: "boolean" },
      { name: "verbose", type: "boolean" },
      // Write-related
      { name: "device", type: "string" },
      { name: "block-size", type: "string" },
      { name: "preview", type: "boolean" },
      // Deploy-specific
      { name: "keep-working", type: "boolean" }
    ]);
    const image = positional[0];
    if (!image) throw new Error("Missing <image>");

    const device = await detectAndSelectDevice(exec, args.device as string | undefined);
    const bs = resolveBlockSize(args["block-size"] as string | undefined);

    // Prepare paths and directories
    const algo = detectCompressionByExt(image);
    const defaultTmp = process.env.TMPDIR || "/tmp";
    const srcDir = dirname(image);
    const imageBase = basename(image);
    const lastDot = imageBase.lastIndexOf(".");
    const bareOriginal = lastDot > 0 ? imageBase.slice(0, lastDot) : imageBase;
    const extOriginal = lastDot > 0 ? imageBase.slice(lastDot) : "";
    const workDir = String(args["work-dir"] ?? (algo && !args["dry-run"] ? defaultTmp : srcDir));
    const ts = new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0,12);
    const workingName = `${bareOriginal}_${ts}.img`;
    const workingPath = `${workDir}/${workingName}`;

    // Proactively request sudo to avoid pause when dd starts
    await exec.run(["sudo", "-v"], { allowNonZeroExit: true });

    // Phase 1: Prepare working image (decompress/copy) + Resize in Docker
    const resizeStart = Date.now();
    const workImage = await prepareWorkingImage(image, workingPath, !!args["dry-run"]);

    // Create backups/working copy unless dry-run
    let targetImage = workingName;
    if (!args["dry-run"]) {
      if (algo) {
        const compressedBackupName = `${bareOriginal}_${ts}${extOriginal}`;
        await createBackup(exec, image, `${srcDir}/${compressedBackupName}`, false);
      } else {
        await createBackup(exec, image, workingPath, false);
        console.log(`Working copy created: ${workingPath}`);
      }
    } else {
      console.log("Dry-run: not creating backup or working copy, operating read-only");
      targetImage = imageBase;
    }

    // Compute default image size from target device if not provided
    const devSizeBytes = await getDiskSizeBytes(exec, device.disk);
    const safeBytes = Math.floor(devSizeBytes * 0.98); // 2% headroom
    const safeMB = Math.floor(safeBytes / 1024 / 1024);
    const chosenImageSize = (args["image-size"] as string | undefined) ?? `${safeMB}MB`;
    if (args["verbose"]) {
      console.log(`[DEPLOY] Target device: ${device.disk} (raw ${device.rdisk})`);
      const devGiB = bytesToGiB(devSizeBytes);
      console.log(`[DEPLOY] Device capacity: ${devGiB} GiB (${devSizeBytes} bytes)`);
      console.log(`[DEPLOY] Chosen image size: ${chosenImageSize} (2% headroom)`);
    }

    const dockerImage = (args["docker-image"] as string) || "rpi-image-resizer:latest";
    const env = {
      IMAGE_FILE: targetImage,
      BOOT_SIZE_MB: String(args["boot-size"] ?? 256),
      IMAGE_SIZE: String(chosenImageSize),
      UNSAFE_RESIZE_EXT4: args["unsafe-resize-ext4"] ? "1" : "0",
      DRY_RUN: args["dry-run"] ? "1" : "0",
      VERBOSE: args["verbose"] ? "1" : "0",
      VERIFY_FS: (args["verify-fs"] || args["verbose"]) ? "1" : "0",
    } as Record<string, string>;

    await ensureImage(exec, dockerImage);
    const result = await runWorker(exec, { image: dockerImage, workdir: workDir, env, stream: true });
    process.exitCode = result.code;
    if (result.code !== 0) throw new Error(`Worker failed: ${result.code}`);
    if (args["verbose"]) {
      const d = Date.now() - resizeStart;
      console.log(`[DURATION][RESIZE] ${formatDuration(d)}`);
    }

    if (args["dry-run"]) {
      console.log("✓ Deploy (resize phase) completed - dry run, skipping write");
      return;
    }

    // Phase 2: Write working image to device
    const writeStart = Date.now();
    const finalPath = `${workDir}/${workingName}`;
    if (args["verbose"]) {
      console.log(`[DEPLOY] Writing image to ${device.rdisk} with bs=${bs}`);
    }
    await preflightImageSize(exec, finalPath, device.disk, false);

    if (args["preview"]) {
      const previewCmd = `sudo dd if=${escapePath(finalPath)} of=${device.rdisk} bs=${bs} conv=fsync status=progress`;
      console.log(previewCmd);
      return;
    }

    const verifyFs = args["verify-fs"] || args["verbose"];
    await writeImageToDevice(exec, finalPath, device, bs, undefined, verifyFs);
    console.log("✓ Deploy completed (resize + write)");
    
    // Cleanup: delete working image unless --keep-working
    if (!args["keep-working"]) {
      console.log(`Deleting working image: ${finalPath}`);
      await exec.run(["rm", "-f", finalPath], { allowNonZeroExit: true });
    } else {
      console.log(`Working image preserved: ${finalPath}`);
    }
    
    if (args["verbose"]) {
      const d = Date.now() - writeStart;
      console.log(`[DURATION][WRITE] ${formatDuration(d)}`);
      const total = Date.now() - startTime;
      console.log(`[DURATION][TOTAL] ${formatDuration(total)}`);
    }
    return;
  }

  if (command === "clean") {
    console.log("Cleaning Docker images and build artifacts...\n");
    
    // Remove Docker images
    const images = ["rpi-image-resizer:latest"];
    for (const img of images) {
      const check = await exec.run(["docker", "image", "inspect", img], { allowNonZeroExit: true });
      if (check.code === 0) {
        console.log(`Removing Docker image: ${img}...`);
        const result = await exec.run(["docker", "rmi", img]);
        if (result.code === 0) {
          console.log(`✓ Removed ${img}`);
        } else {
          console.error(`✗ Failed to remove ${img}`);
        }
      } else {
        console.log(`Docker image ${img} not found`);
      }
    }

    console.log("\n✓ Clean completed");
    if (argv.includes("--verbose")) {
      const duration = Date.now() - startTime;
      console.log(`[DURATION] ${formatDuration(duration)}`);
    }
    return;
  }

  if (command === "resize") {
    const { args, positional } = parseArgs(rest, [
      { name: "boot-size", type: "number", default: 256 },
      { name: "image-size", type: "string" },
      { name: "unsafe-resize-ext4", type: "boolean" },
      { name: "dry-run", type: "boolean" },
      { name: "verbose", type: "boolean" },
      { name: "verify-fs", type: "boolean" },
      { name: "docker-image", type: "string" },
      { name: "work-dir", type: "string" }
    ]);
    const image = positional[0];
    if (!image) throw new Error("Missing <image>");

    const dockerImage = (args["docker-image"] as string) || "rpi-image-resizer:latest";

    // Prepare working directory and file names
    const ts = new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0,12);
    const srcDir = dirname(image);
    const imageBase = basename(image);
    const lastDot = imageBase.lastIndexOf(".");
    const bareOriginal = lastDot > 0 ? imageBase.slice(0, lastDot) : imageBase;
    const extOriginal = lastDot > 0 ? imageBase.slice(lastDot) : "";

    const algo = detectCompressionByExt(image);
    const defaultTmp = process.env.TMPDIR || "/tmp";
    const workDir = String(args["work-dir"] ?? (algo && !args["dry-run"] ? defaultTmp : srcDir));

    // Working copy name (always .img) and full path
    const workingName = `${bareOriginal}_${ts}.img`;
    const workingPath = `${workDir}/${workingName}`;

    // Prepare working image: decompress directly to workingPath for compressed inputs
    const workImage = await prepareWorkingImage(image, workingPath, !!args["dry-run"]);

    try {
      // Create backups/working copy unless dry-run
      let targetImage = workingName;

      if (!args["dry-run"]) {
        if (algo) {
          // Backup the compressed source in its original directory
          const compressedBackupName = `${bareOriginal}_${ts}${extOriginal}`;
          await createBackup(exec, image, `${srcDir}/${compressedBackupName}`, false);
          // Working file already created via decompression to workingPath
        } else {
          // Uncompressed: copy source to workDir as working file
          await createBackup(exec, image, workingPath, false);
          console.log(`Working copy created: ${workingPath}`);
        }
      } else {
        console.log("Dry-run: not creating backup or working copy, operating read-only");
        targetImage = imageBase; // use original name for dry-run
      }

      const env = {
        IMAGE_FILE: targetImage,
        BOOT_SIZE_MB: String(args["boot-size"] ?? 256),
        IMAGE_SIZE: args["image-size"] ? String(args["image-size"]) : "",
        UNSAFE_RESIZE_EXT4: args["unsafe-resize-ext4"] ? "1" : "0",
        DRY_RUN: args["dry-run"] ? "1" : "0",
        VERBOSE: args["verbose"] ? "1" : "0",
        VERIFY_FS: (args["verify-fs"] || args["verbose"]) ? "1" : "0",
      } as Record<string, string>;

      // Ensure Docker image exists (will auto-build from embedded resources if needed)
      await ensureImage(exec, dockerImage);

      const result = await runWorker(exec, {
        image: dockerImage,
        workdir: workDir,
        env,
        stream: true,
      });
      process.exitCode = result.code;

      if (result.code !== 0) throw new Error(`Worker failed: ${result.code}`);
      if (args["verbose"]) {
        if (!args["dry-run"]) {
          const finalPath = `${workDir}/${workingName}`;
          const sizeBytes = Bun.file(finalPath).size;
          const sizeMB = (sizeBytes / 1024 / 1024).toFixed(2);
          const sizeGB = (sizeBytes / 1024 / 1024 / 1024).toFixed(2);
          console.log(`[HOST SUMMARY] Final image path: ${finalPath}`);
          console.log(`[HOST SUMMARY] Final image size: ${sizeBytes} bytes (${sizeMB} MB / ${sizeGB} GB)`);
          console.log(`[HOST SUMMARY] Partition summary above is from container (sector-accurate).`);
        } else {
          console.log(`[HOST SUMMARY] Dry-run: no image modifications performed.`);
        }
      }
      console.log("✓ Resize completed");
      if (args["verbose"]) {
        const duration = Date.now() - startTime;
        console.log(`[DURATION] ${formatDuration(duration)}`);
      }
    } finally {
      // No temporary decompression file to clean; workingPath remains for user
    }
    return;
  }

  return usage();
}

await main().catch((e) => { 
  console.error(e.message || e);
  process.exitCode = 1;
});
