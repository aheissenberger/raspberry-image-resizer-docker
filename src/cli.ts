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
  `  size                       Show size of removable device (macOS)\n\n` +
`Global Options:\n  -h, --help                 Show help\n  -v, --version              Show version\n\n` +
  `Clone/Write/Size Options:\n  --compress <zstd|xz|gzip>  Compress output during clone\n  --level <n>                Compression level\n  --block-size <SIZE>        dd block size (default 4m)\n  --device </dev/diskN>      Override auto-detect; use specific disk (advanced)\n  --yes                      Skip confirmations (write only; dangerous)\n  --preview                  Print the dd command and exit (no changes)\n\n` +
`Resize Options:\n  --boot-size <MB>           Target boot partition size (default 256)\n  --image-size <SIZE>        Change overall image size (e.g. 32GB, 8192MB)\n  --unsafe-resize-ext4       Run resize2fs on root when not moving (unsafe)\n  --dry-run                  Plan only, do not modify\n  --verbose                  Verbose logs\n  --docker-image <name>      Docker image name (default rpi-image-resizer:latest)\n  --work-dir <path>          Working directory for temp files (default: TMPDIR or /tmp for compressed)\n`);
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

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("-h") || argv.includes("--help")) return usage();
  if (argv.includes("-v") || argv.includes("--version")) { console.log(VERSION); return; }
  const [command, ...rest] = argv;
  if (!command) return usage();

  // Support `version` as a command
  if (command === "version") { console.log(VERSION); return; }

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
    return;
  }

  if (command === "write") {
    const { args, positional } = parseArgs(rest, [
      { name: "device", type: "string" } // optional explicit device: /dev/diskN
    ]);
    const image = positional[0];
    if (!image) throw new Error("Missing <image>");

    // choose target device
    let selected: string | undefined = (args.device as string | undefined);
    if (!selected) {
      const disks = (await exec.run(["bash", "-lc", "diskutil list | grep -E '^/dev/disk[0-9]+' | awk '{print $1}'"]))
        .stdout.trim().split(/\s+/).filter(Boolean);
      for (const d of disks) {
        const info = await exec.run(["bash", "-lc", `diskutil info ${d} | grep 'Removable Media:' | grep -q Removable && echo yes || echo no`]);
        if (info.stdout.trim() === "yes") { selected = d; break; }
      }
    }
    if (!selected) throw new Error("No removable device detected for write");
    const raw = selected.replace("/dev/disk", "/dev/rdisk");

    // detect decompressor
    const algo = detectCompressionByExt(image);
    const decomp = algo ? buildDecompressor(algo) : undefined;

    // Preflight: if image is uncompressed, ensure device capacity >= image size
    if (!decomp) {
      const imgSize = Bun.file(image).size;
      const devSize = await getDiskSizeBytes(exec, selected);
      if (imgSize > devSize) {
        throw new Error(
          `Image (${bytesToGiB(imgSize)}) is larger than device ${selected} (${bytesToGiB(devSize)}). ` +
          `Use 'rpi-tool resize --image-size <smaller size>' to shrink the image or choose a larger device.`
        );
      }
    } else {
      // Optional: warn we cannot preflight exact size for compressed streams
      console.error("Note: writing from compressed stream; exact uncompressed size preflight is not available.");
    }

    // Unmount volumes (best-effort)
    await exec.run(["diskutil", "unmountDisk", selected], { allowNonZeroExit: true });

    // dd command with conv=fsync to flush writes
    if (decomp) {
      const cmd = `${decomp.join(" ")} ${escapePath(image)} | sudo dd of=${raw} bs=4m conv=fsync status=progress 2>/dev/stderr`;
      console.log(`About to WRITE image to device: ${selected} (raw ${raw})`);
      await exec.run(["bash", "-lc", cmd]);
    } else {
      console.log(`About to WRITE image to device: ${selected} (raw ${raw})`);
      await exec.run(["bash", "-lc", `sudo dd if=${escapePath(image)} of=${raw} bs=4m conv=fsync status=progress 2>/dev/stderr`]);
    }

    await exec.run(["sync"], { allowNonZeroExit: true });
    await exec.run(["diskutil", "mountDisk", selected], { allowNonZeroExit: true });
    console.log("✓ Write completed");
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
    return;
  }

  if (command === "resize") {
    const { args, positional } = parseArgs(rest, [
      { name: "boot-size", type: "number", default: 256 },
      { name: "image-size", type: "string" },
      { name: "unsafe-resize-ext4", type: "boolean" },
      { name: "dry-run", type: "boolean" },
      { name: "verbose", type: "boolean" },
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
    let workImage = image;
    if (algo) {
      console.error(`Detected ${algo} compressed image`);
      if (args["dry-run"]) {
        console.error("Dry-run: skipping decompression");
        workImage = image; // Use compressed file path for dry-run
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
        workImage = workingPath;
        console.log(`Working copy created: ${workingPath}`);
      }
    }

    try {
      // Create backups/working copy unless dry-run
      let targetImage = workingName;

      if (!args["dry-run"]) {
        if (algo) {
          // Backup the compressed source in its original directory
          const compressedBackupName = `${bareOriginal}_${ts}${extOriginal}`;
          await exec.run(["cp", image, `${srcDir}/${compressedBackupName}`]);
          console.log(`Backup created: ${srcDir}/${compressedBackupName}`);
          // Working file already created via decompression to workingPath
        } else {
          // Uncompressed: copy source to workDir as working file
          await exec.run(["cp", image, workingPath]);
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
      } as Record<string, string>;

      // Ensure Docker image exists (will auto-build from embedded resources if needed)
      await ensureImage(exec, dockerImage);

      const result = await runWorker(exec, {
        image: dockerImage,
        workdir: workDir,
        env,
      });
      process.exitCode = result.code;
      if (result.code !== 0) throw new Error(`Worker failed: ${result.code}`);
      console.log("✓ Resize completed");
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
