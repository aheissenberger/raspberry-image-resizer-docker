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
`Global Options:\n  -h, --help                 Show help\n  -v, --version              Show version\n\n` +
`Clone/Write Options:\n  --compress <zstd|xz|gzip>  Compress output during clone\n  --level <n>                Compression level\n  --block-size <SIZE>        dd block size (default 4m)\n  --device </dev/diskN>      Override auto-detect; use specific disk (advanced)\n  --yes                      Skip confirmations (write only; dangerous)\n  --preview                  Print the dd command and exit (no changes)\n\n` +
`Resize Options:\n  --boot-size <MB>           Target boot partition size (default 256)\n  --image-size <SIZE>        Change overall image size (e.g. 32GB, 8192MB)\n  --unsafe-resize-ext4       Run resize2fs on root when not moving (unsafe)\n  --dry-run                  Plan only, do not modify\n  --verbose                  Verbose logs\n  --docker-image <name>      Docker image name (default rpi-image-resizer:latest)\n`);
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

  if (command === "write") {
    const { args: _args, positional } = parseArgs(rest, [
      { name: "block-size", type: "string" },
      { name: "device", type: "string" },
      { name: "yes", type: "boolean" },
      { name: "preview", type: "boolean" }
    ]);
    const image = positional[0];
    if (!image) throw new Error("Missing <image>");
    const bs = resolveBlockSize(_args["block-size"] as string | undefined);

    // choose target device
    const selected = _args.device ? normalizeDevice(String(_args.device)).disk : await detectRemovableDisk(exec);
    if (!selected) throw new Error("No removable device detected for write");
    const raw = _args.device ? normalizeDevice(String(_args.device)).rdisk : selected.replace("/dev/disk", "/dev/rdisk");

    // Double confirmation for destructive write (unless --yes)
    if (!_args.yes) {
      const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
      const ask = (q: string) => new Promise<string>((resolve) => rl.question(q, (ans) => resolve(ans.trim())));
      console.warn(`About to WRITE image to device: ${selected} (raw ${raw})`);
      const ans1 = await ask("Are you sure you want to proceed? Type 'yes' to continue: ");
      if (ans1.toLowerCase() !== "yes") {
        rl.close();
        console.error("Aborted by user.");
        return;
      }
      const ans2 = await ask("Final confirmation: type 'WRITE' to proceed: ");
      rl.close();
      if (ans2 !== "WRITE") {
        console.error("Aborted by user.");
        return;
      }
    } else {
      console.warn("--yes provided: skipping interactive confirmations (dangerous).");
    }

    // detect decompressor
    const algo = detectCompressionByExt(image);
    const decomp = algo ? buildDecompressor(algo) : undefined;

    // Build dd command and optionally preview
    const ddCmdW = buildWriteDdCommand({ rawDevice: raw, imagePath: escapePath(image), blockSize: bs, decompressor: decomp });
    if (_args.preview) {
      console.log(ddCmdW);
      return;
    }

    await exec.run(["diskutil", "unmountDisk", selected], { allowNonZeroExit: true });
    await exec.run(["bash", "-lc", ddCmdW], { onStderrChunk: (s) => process.stderr.write(s) });

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
      { name: "docker-image", type: "string" }
    ]);
    const image = positional[0];
    if (!image) throw new Error("Missing <image>");

    const dockerImage = (args["docker-image"] as string) || "rpi-image-resizer:latest";

    // If compressed, decompress to temp file first (unless dry-run)
    let workImage = image;
    const algo = detectCompressionByExt(image);
    let tempPath: string | undefined;
    if (algo) {
      console.error(`Detected ${algo} compressed image`);
      if (args["dry-run"]) {
        console.error("Dry-run: skipping decompression");
        workImage = image; // Use compressed file path for dry-run
      } else {
        const decomp = buildDecompressor(algo);
        tempPath = `${image}.decompressed.tmp`;
        // Use shell redirection for decompression since these tools read from file args
        decomp.push(image);
        const proc = spawn({
          cmd: decomp,
          stdout: Bun.file(tempPath),
          stderr: "pipe",
        });
        const exitCode = await proc.exited;
        const stderr = await new Response(proc.stderr).text();
        
        if (exitCode !== 0) {
          throw new Error(`Decompression failed with code ${exitCode}\n${stderr}`);
        }
        workImage = tempPath;
      }
    }

    try {
      // Create a timestamped backup copy unless dry-run
      const ts = new Date().toISOString().replace(/[-:TZ.]/g, "").slice(0,12);
      const srcDir = dirname(image);
      const imageBase = basename(image);
      const lastDot = imageBase.lastIndexOf(".");
      const bareOriginal = lastDot > 0 ? imageBase.slice(0, lastDot) : imageBase;
      const extOriginal = lastDot > 0 ? imageBase.slice(lastDot) : "";

      // Working copy name (always .img)
      const workingName = `${bareOriginal}_${ts}.img`;
      let targetImage = workingName;

      if (!args["dry-run"]) {
        if (algo) {
          // Backup the compressed source
          const compressedBackupName = `${bareOriginal}_${ts}${extOriginal}`;
          await exec.run(["cp", image, `${srcDir}/${compressedBackupName}`]);
          console.log(`Backup created: ${srcDir}/${compressedBackupName}`);
          // Create working copy from decompressed temp
          await exec.run(["cp", workImage, `${srcDir}/${workingName}`]);
          console.log(`Working copy created: ${srcDir}/${workingName}`);
        } else {
          // Uncompressed: single backup/working copy
          await exec.run(["cp", image, `${srcDir}/${workingName}`]);
          console.log(`Backup created: ${srcDir}/${workingName}`);
        }
      } else {
        console.log("Dry-run: not creating backup, operating read-only");
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
        workdir: srcDir,
        env,
      });
      process.exitCode = result.code;
      if (result.code !== 0) throw new Error(`Worker failed: ${result.code}`);
      console.log("✓ Resize completed");
    } finally {
      if (tempPath) {
        await exec.run(["rm", "-f", tempPath], { allowNonZeroExit: true });
      }
    }
    return;
  }

  return usage();
}

await main().catch((e) => { 
  console.error(e.message || e);
  process.exitCode = 1;
});
