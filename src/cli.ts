#!/usr/bin/env bun
import { spawn } from "bun";
import { parseArgs } from "./lib/args";
import { BunExecutor } from "./lib/executor";
import { buildCompressor, buildDecompressor, detectCompressionByExt, validateLevel } from "./lib/compress";
import { ensureImage, runWorker } from "./lib/docker";
import pkg from "../package.json";

const VERSION: string = (pkg as any).version || "0.0.0";

function usage() {
  console.log(`raspberry-image-tool v${VERSION}\n\n` +
`Usage:\n  rpi-tool <command> [options]\n\n` +
`Commands:\n  version                    Print version\n  clone <output-image>       Clone SD to image (macOS)\n  write <image>              Write image to SD (macOS)\n  resize <image>             Resize and adjust partitions (Docker)\n  clean                      Remove Docker images\n\n` +
`Global Options:\n  -h, --help                 Show help\n  -v, --version              Show version\n\n` +
`Clone/Write Options:\n  --compress <zstd|xz|gzip>  Compress output during clone\n  --level <n>                Compression level\n\n` +
`Resize Options:\n  --boot-size <MB>           Target boot partition size (default 256)\n  --image-size <SIZE>        Change overall image size (e.g. 32GB, 8192MB)\n  --unsafe-resize-ext4       Run resize2fs on root when not moving (unsafe)\n  --dry-run                  Plan only, do not modify\n  --verbose                  Verbose logs\n  --docker-image <name>      Docker image name (default rpi-image-resizer:latest)\n`);
}

function escapePath(p: string) {
  return `'${p.replaceAll("'", "'\\''")}'`;
}
function dirname(p: string) { return p.substring(0, p.lastIndexOf("/")) || "."; }
function basename(p: string) { return p.substring(p.lastIndexOf("/") + 1); }

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
      { name: "level", type: "number" }
    ]);
    const output = positional[0];
    if (!output) throw new Error("Missing <output-image>");

    // Scan removable devices
    const list = await exec.run(["diskutil", "list"]);
    if (list.code !== 0) throw new Error("diskutil list failed");
    // Simple interactive-less path: select first removable with boot partition
    const disks = (await exec.run(["bash", "-lc", "diskutil list | grep -E '^/dev/disk[0-9]+' | awk '{print $1}'"]))
      .stdout.trim().split(/\s+/).filter(Boolean);

    let selected: string | undefined;
    for (const d of disks) {
      // check removable
      const info = await exec.run(["bash", "-lc", `diskutil info ${d} | grep 'Removable Media:' | grep -q Removable && echo yes || echo no`]);
      if (info.stdout.trim() !== "yes") continue;
      // check FAT boot partition
      const hasBoot = await exec.run(["bash", "-lc", `diskutil list ${d} | grep -E 'Windows_FAT_32.* boot' -q && echo yes || echo no`]);
      if (hasBoot.stdout.trim() === "yes") { selected = d; break; }
    }
    if (!selected) throw new Error("No removable Raspberry Pi SD card detected");

    const raw = selected.replace("/dev/disk", "/dev/rdisk");

    // Progress will be shown via dd's status=progress (or SIGINFO on macOS)

    // Optional compression
    let compressor: string[] | undefined;
    if (args.compress) {
      const algo = String(args.compress) as any;
      validateLevel(algo, args.level);
      compressor = buildCompressor(algo, args.level);
    }

    // Unmount volumes (best-effort)
    await exec.run(["diskutil", "unmountDisk", selected], { allowNonZeroExit: true });

    // dd command with progress only using dd capabilities
    if (compressor) {
      const pipeCmd = `sudo dd if=${raw} bs=1m status=progress 2>/dev/stderr | ${compressor.join(" ")} > ${escapePath(output)}`;
      await exec.run(["bash", "-lc", pipeCmd], { onStderrChunk: (s) => process.stderr.write(s) });
    } else {
      const cmd = `sudo dd if=${raw} of=${escapePath(output)} bs=1m status=progress`;
      await exec.run(["bash", "-lc", cmd], { onStderrChunk: (s) => process.stderr.write(s) });
    }

    await exec.run(["sync"], { allowNonZeroExit: true });
    await exec.run(["diskutil", "mountDisk", selected], { allowNonZeroExit: true });
    console.log("✓ Clone completed");
    return;
  }

  if (command === "write") {
    const { args: _args, positional } = parseArgs(rest, []);
    const image = positional[0];
    if (!image) throw new Error("Missing <image>");

    // choose target device
    const disks = (await exec.run(["bash", "-lc", "diskutil list | grep -E '^/dev/disk[0-9]+' | awk '{print $1}'"]))
      .stdout.trim().split(/\s+/).filter(Boolean);
    let selected: string | undefined;
    for (const d of disks) {
      const info = await exec.run(["bash", "-lc", `diskutil info ${d} | grep 'Removable Media:' | grep -q Removable && echo yes || echo no`]);
      if (info.stdout.trim() === "yes") { selected = d; break; }
    }
    if (!selected) throw new Error("No removable device detected for write");
    const raw = selected.replace("/dev/disk", "/dev/rdisk");

    // detect decompressor
    const algo = detectCompressionByExt(image);
    const decomp = algo ? buildDecompressor(algo) : undefined;

    await exec.run(["diskutil", "unmountDisk", selected], { allowNonZeroExit: true });

    // Progress for write using dd only
    if (decomp) {
      const cmd = `${decomp.join(" ")} ${escapePath(image)} | sudo dd of=${raw} bs=1m status=progress 2>/dev/stderr`;
      await exec.run(["bash", "-lc", cmd], { onStderrChunk: (s) => process.stderr.write(s) });
    } else {
      const cmd = `sudo dd if=${escapePath(image)} of=${raw} bs=1m status=progress`;
      await exec.run(["bash", "-lc", cmd], { onStderrChunk: (s) => process.stderr.write(s) });
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
      const dir = dirname(workImage);
      const base = basename(workImage);
      const bare = base.replace(/\.[^.]+$/, "");
      const backupName = `${bare}_${ts}.img`;
      let targetImage = base;

      if (!args["dry-run"]) {
        await exec.run(["cp", workImage, `${dir}/${backupName}`]);
        targetImage = backupName;
        console.log(`Backup created: ${dir}/${backupName}`);
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
        workdir: dir,
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
