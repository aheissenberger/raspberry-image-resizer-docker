import { BunExecutor, Executor } from "../lib/executor";
import { existsSync, mkdirSync } from "fs";

// TS version of resize-worker.sh, invoking Linux tools via Executor
// Expects ENV: IMAGE_FILE, BOOT_SIZE_MB, IMAGE_SIZE, UNSAFE_RESIZE_EXT4, DRY_RUN, VERBOSE

const env = (k: string, d?: string) => (process.env[k] ?? d ?? "");
const INFO = (s: string) => console.log(`[INFO] ${s}`);
const WARN = (s: string) => console.log(`[WARN] ${s}`);
const ERROR = (s: string) => console.error(`[ERROR] ${s}`);

const DRY = env("DRY_RUN") === "1";

async function run(exe: Executor) {
  const IMAGE_FILE = env("IMAGE_FILE");
  if (!IMAGE_FILE) throw new Error("IMAGE_FILE not set");
  const BOOT_SIZE_MB = Number(env("BOOT_SIZE_MB", "256"));
  const IMAGE_SIZE = env("IMAGE_SIZE");
  const UNSAFE = env("UNSAFE_RESIZE_EXT4") === "1";

  const imagePath = `/work/${IMAGE_FILE}`;

  // validate file exists
  if (!existsSync(imagePath)) {
    throw new Error(`Image file not found: ${imagePath}`);
  }

  INFO("=== Raspberry Pi Image Resizer Worker ===");
  INFO(`Image file: ${IMAGE_FILE}`);
  INFO(`Target boot size: ${BOOT_SIZE_MB}MB`);
  if (IMAGE_SIZE) INFO(`Target image size: ${IMAGE_SIZE}`);
  if (UNSAFE) WARN("Unsafe ext4 resizing enabled");
  if (DRY) WARN("DRY RUN mode active");

  // Step 0: Adjust image size if requested
  let imageExpanded = false, imageShrunk = false;
  if (IMAGE_SIZE) {
    INFO("Step 0: Adjusting image file size...");
    const { bytes: targetBytes, pretty: targetPretty } = parseSize(IMAGE_SIZE);
    const currentBytes = Bun.file(imagePath).size;
    if (targetBytes === currentBytes) {
      INFO("Image already at target size");
    } else if (targetBytes > currentBytes) {
      const expMB = Math.floor((targetBytes - currentBytes) / (1024 * 1024));
      INFO(`Expanding image by ${expMB}MB to ${targetPretty}...`);
      if (!DRY) await exe.run(["truncate", "-s", String(targetBytes), imagePath]);
      imageExpanded = true;
    } else {
      // shrink: validate against last partition end + safety margin
      INFO("Shrinking image - validating partition boundaries...");
      if (!DRY) {
        const loop = (await exe.run(["losetup", "-f", "--show", imagePath])).stdout.trim();
        const dump = await exe.run(["sfdisk", "-d", loop], { allowNonZeroExit: true });
        await exe.run(["losetup", "-d", loop], { allowNonZeroExit: true });
        let lastEnd = 0;
        for (const line of dump.stdout.split("\n")) {
          const m = line.match(/start=\s*(\d+).+size=\s*(\d+)/);
          if (m) {
            const start = Number(m[1]);
            const size = Number(m[2]);
            const end = start + size - 1;
            if (end > lastEnd) lastEnd = end;
          }
        }
        const minBytes = (lastEnd + 20480) * 512; // +10MB
        if (targetBytes < minBytes) {
          const minMB = Math.floor(minBytes / 1024 / 1024);
          throw new Error(`Cannot shrink image below ${minMB}MB (partition boundary + safety)`);
        }
        await exe.run(["truncate", "-s", String(targetBytes), imagePath]);
        imageShrunk = true;
      }
    }
  }

  // Step 1: Attach loop, map partitions
  INFO("Step 1: Attaching image as loop device...");
  let loop = "/dev/loop0";
  if (!DRY) {
    loop = (await exe.run(["losetup", "-f", "--show", "-P", imagePath])).stdout.trim();
    await exe.run(["partprobe", loop], { allowNonZeroExit: true });
  }

  // Step 2: Identify boot/root partitions
  INFO("Step 2: Examining partition layout...");
  let bootPart = `${loop}p1`;
  let rootPart = `${loop}p2`;
  if (!DRY) {
    const hasP1 = existsSync(`${loop}p1`);
    if (!hasP1) {
      await exe.run(["kpartx", "-av", loop], { allowNonZeroExit: true });
      const base = loop.split("/").pop();
      bootPart = `/dev/mapper/${base}p1`;
      rootPart = `/dev/mapper/${base}p2`;
    }
    if (!existsSync(bootPart) || !existsSync(rootPart)) {
      throw new Error(`Partition devices not found: ${bootPart}, ${rootPart}`);
    }
  }

  // Step 3: Backup boot files
  INFO("Step 3: Backing up boot partition files...");
  if (!DRY) {
    mkdirSync("/mnt/boot", { recursive: true });
    mkdirSync("/boot-backup", { recursive: true });
    await exe.run(["mount", bootPart, "/mnt/boot"]);
    await exe.run(["rsync", "-a", "/mnt/boot/", "/boot-backup/"]);
    await exe.run(["umount", "/mnt/boot"], { allowNonZeroExit: true });
  }

  // Step 4: Calculate new layout via sfdisk dump
  INFO("Step 4: Calculating new partition layout...");
  let ptdump = "";
  if (!DRY) {
    ptdump = (await exe.run(["sfdisk", "-d", loop], { allowNonZeroExit: true })).stdout;
  }
  const layout = parseSfdiskDump(ptdump, loop);
  const bootSizeSectors = (BOOT_SIZE_MB * 1024 * 1024) / 512 | 0;
  const bootNewEnd = layout.boot.start + bootSizeSectors - 1;
  let needsRootMove = bootNewEnd >= layout.root.start;

  // If move required, check ext4 and compute new positions
  let rootNewStart = layout.root.start;
  let rootNewEnd = layout.root.end;
  let needsRootShrink = false;
  if (!DRY && needsRootMove) {
    // check filesystems
    const blkidResult = await exe.run(["blkid", "-s", "TYPE", "-o", "value", rootPart], { allowNonZeroExit: true });
    const rootFs = blkidResult.stdout.trim() || "unknown";
    if (rootFs !== "ext4") throw new Error(`Root partition is not ext4 (detected ${rootFs})`);

    rootNewStart = Math.ceil((bootNewEnd + 2048) / 2048) * 2048; // 1MB aligned
    rootNewEnd = rootNewStart + (layout.root.end - layout.root.start);
    // Determine total disk sectors from blockdev (layout dump may not include it)
    const diskSectors = Number((await exe.run(["blockdev", "--getsz", loop])).stdout.trim());
    const maxEnd = diskSectors > 0 ? (diskSectors - 1) : rootNewEnd;
    if (rootNewEnd > maxEnd) {
      needsRootShrink = true;
      rootNewEnd = maxEnd - 100 * 1024 * 1024 / 512; // 100MB buffer
    }
  }

  // Step 5: Shrink root if required
  if (needsRootShrink && !DRY) {
    INFO("Step 5: Shrinking root partition...");
    const e2fsckResult = await exe.run(["e2fsck", "-f", "-y", rootPart], { allowNonZeroExit: true });
    if (e2fsckResult.code > 2) {
      ERROR(`e2fsck stdout: ${e2fsckResult.stdout}`);
      ERROR(`e2fsck stderr: ${e2fsckResult.stderr}`);
      throw new Error(`e2fsck failed with code ${e2fsckResult.code}`);
    }
    const targetMB = Math.floor((rootNewEnd - rootNewStart + 1) * 512 / 1024 / 1024);
    await exe.run(["resize2fs", rootPart, `${targetMB}M`]);
    // write shrunk table at CURRENT location (will be moved in Step 5b if needed)
    const bootSize = layout.boot.end - layout.boot.start + 1;
    const rootSize = rootNewEnd - rootNewStart + 1;
    // Keep root at current location during shrink, will move later
    const sfd = sfdiskTable(loop, layout.boot.start, bootSize, layout.root.start, rootSize);
    await exe.run(["sfdisk", "--force", "--no-reread", loop], { stdin: sfd });
    await rereadMappings(exe, loop);
  } else {
    INFO("Step 5: Root partition does not need to be shrunk");
  }

  // Step 5b: Move root if required
  if (needsRootMove && !DRY) {
    INFO("Step 5b: Moving root partition...");
    const e2fsckResult = await exe.run(["e2fsck", "-f", "-y", rootPart], { allowNonZeroExit: true });
    if (e2fsckResult.code > 2) {
      ERROR(`e2fsck stdout: ${e2fsckResult.stdout}`);
      ERROR(`e2fsck stderr: ${e2fsckResult.stderr}`);
      throw new Error(`e2fsck failed with code ${e2fsckResult.code}`);
    }

    const oldStart = layout.root.start;
    // Use the NEW size (after shrinking) not the original size
    const sizeSectors = rootNewEnd - rootNewStart + 1;
    // After shrinking, the data ends at oldStart + sizeSectors - 1
    const oldEnd = oldStart + sizeSectors - 1;
    // Overlap-safe copy: compare ranges
    const overlaps = rootNewStart <= oldEnd && (rootNewStart + sizeSectors - 1) >= oldStart;
    if (overlaps) {
      // Backward copy in chunks
      const block = 128; // sectors per chunk
      let remain = sizeSectors;
      let progress = 0;
      while (remain > 0) {
        const cur = Math.min(remain, block);
        const offFromEnd = progress + cur;
        const srcStart = oldEnd - offFromEnd + 1;
        const dstStart = rootNewStart + (srcStart - oldStart);
        await exe.run(["dd", "if=" + loop, "of=" + loop, "bs=512", `skip=${srcStart}`, `seek=${dstStart}`, `count=${cur}`, "conv=notrunc"], { allowNonZeroExit: false });
        progress += cur;
        remain -= cur;
      }
    } else {
      await exe.run(["dd", "if=" + loop, "of=" + loop, "bs=512", `skip=${oldStart}`, `seek=${rootNewStart}`, `count=${sizeSectors}`, "conv=notrunc", "status=progress"]);
    }

    // Rewrite table with moved root
    const bootSize = layout.boot.end - layout.boot.start + 1;
    const rootSize = sizeSectors;
    const sfd = sfdiskTable(loop, layout.boot.start, bootSize, rootNewStart, rootSize);
    await exe.run(["sfdisk", "--force", "--no-reread", loop], { stdin: sfd });
    await rereadMappings(exe, loop);

    // Re-evaluate rootPart path (mapper vs pN)
    const base = loop.split("/").pop()!;
    const mapperRoot = `/dev/mapper/${base}p2`;
    rootPart = existsSync(mapperRoot) ? mapperRoot : `${loop}p2`;

    const e2fsckResult2 = await exe.run(["e2fsck", "-f", "-y", rootPart], { allowNonZeroExit: true });
    if (e2fsckResult2.code > 2) throw new Error(`e2fsck failed with code ${e2fsckResult2.code}`);
  } else {
    INFO("Step 5b: Root partition does not need to be moved");
  }

  // Step 6: Resize boot partition (write table if not already)
  INFO("Step 6: Resizing boot partition...");
  if (!DRY) {
    const bootSize = bootNewEnd - layout.boot.start + 1;
    if (!needsRootMove) {
      const rootSize = layout.root.end - layout.root.start + 1;
      const sfd = sfdiskTable(loop, layout.boot.start, bootSize, layout.root.start, rootSize);
      await exe.run(["sfdisk", "--force", "--no-reread", loop], { stdin: sfd });
      await rereadMappings(exe, loop);
    }
  }

  // Step 7: Create new FAT32 filesystem
  INFO("Step 7: Creating new FAT32 filesystem on boot partition...");
  if (!DRY) {
    // refresh bootPart reference
    const base = loop.split("/").pop()!;
    const mapperBoot = `/dev/mapper/${base}p1`;
    bootPart = existsSync(mapperBoot) ? mapperBoot : `${loop}p1`;

    await exe.run(["mkfs.vfat", "-F", "32", bootPart]);
  }

  // Step 8: Restore boot files
  INFO("Step 8: Restoring boot files...");
  if (!DRY) {
    await exe.run(["mount", bootPart, "/mnt/boot"]);
    await exe.run(["rsync", "-a", "/boot-backup/", "/mnt/boot/"]);
    await exe.run(["umount", "/mnt/boot"], { allowNonZeroExit: true });
  }

  // Step 9: Auto-adjust root after image resize
  if (!DRY && (imageExpanded || imageShrunk)) {
    INFO("Step 9: Adjusting root partition to use available space...");
    const diskSectors = Number((await exe.run(["blockdev", "--getsz", loop])).stdout.trim());

    const dump = (await exe.run(["sfdisk", "-d", loop])).stdout;
    const parsed = parseSfdiskDump(dump, loop);
    const currentRootStart = parsed.root.start;

    const maxRootSizeSectors = diskSectors - currentRootStart - 2048;
    const currRootSize = parsed.root.end - parsed.root.start + 1;

    if (imageExpanded && maxRootSizeSectors > currRootSize) {
      const sfd = sfdiskTable(loop, parsed.boot.start, parsed.boot.end - parsed.boot.start + 1, currentRootStart, maxRootSizeSectors);
      await exe.run(["sfdisk", "--force", "--no-reread", loop], { stdin: sfd });
      await rereadMappings(exe, loop);
      const base = loop.split("/").pop()!;
      const mapperRoot = `/dev/mapper/${base}p2`;
      rootPart = existsSync(mapperRoot) ? mapperRoot : `${loop}p2`;
      const e2fsckResult3 = await exe.run(["e2fsck", "-f", "-y", rootPart], { allowNonZeroExit: true });
      if (e2fsckResult3.code > 2) throw new Error(`e2fsck failed with code ${e2fsckResult3.code}`);
      await exe.run(["resize2fs", rootPart]);
    } else if (imageShrunk && maxRootSizeSectors < currRootSize) {
      const maxMB = Math.floor(maxRootSizeSectors * 512 / 1024 / 1024);
      const e2fsckResult4 = await exe.run(["e2fsck", "-f", "-y", rootPart], { allowNonZeroExit: true });
      if (e2fsckResult4.code > 2) throw new Error(`e2fsck failed with code ${e2fsckResult4.code}`);
      await exe.run(["resize2fs", rootPart, `${maxMB}M`]);
      const sfd = sfdiskTable(loop, parsed.boot.start, parsed.boot.end - parsed.boot.start + 1, currentRootStart, maxRootSizeSectors);
      await exe.run(["sfdisk", "--force", "--no-reread", loop], { stdin: sfd });
      await rereadMappings(exe, loop);
    } else if (UNSAFE && !needsRootMove) {
      WARN("Unsafe resize2fs requested");
      const e2fsckResult5 = await exe.run(["e2fsck", "-f", "-y", rootPart], { allowNonZeroExit: true });
      if (e2fsckResult5.code > 2) throw new Error(`e2fsck failed with code ${e2fsckResult5.code}`);
      await exe.run(["resize2fs", rootPart]);
    }
  } else if (UNSAFE && !needsRootMove) {
    WARN("UNSAFE ext4 resize mode active");
    if (!DRY) {
      const e2fsckResult6 = await exe.run(["e2fsck", "-f", "-y", rootPart], { allowNonZeroExit: true });
      if (e2fsckResult6.code > 2) throw new Error(`e2fsck failed with code ${e2fsckResult6.code}`);
      await exe.run(["resize2fs", rootPart]);
    }
  }

  // Step 10: Final verification
  INFO("Step 10: Final verification...");
  if (!DRY) {
    await exe.run(["sfdisk", "-d", loop], { allowNonZeroExit: true });
    await exe.run(["blkid", bootPart, rootPart], { allowNonZeroExit: true });
    
    // Cleanup: detach loop device
    await exe.run(["kpartx", "-d", loop], { allowNonZeroExit: true });
    await exe.run(["losetup", "-d", loop], { allowNonZeroExit: true });
  }

  INFO("=== Operation completed successfully ===");
}

function parseSize(s: string): { bytes: number; pretty: string } {
  const m = s.match(/^(\d+)([KMGTP]?B?)$/i);
  if (!m) throw new Error(`Invalid size format: ${s}`);
  const n = Number(m[1]);
  const u = m[2].toUpperCase();
  const mult: Record<string, number> = { "": 1, K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4, P: 1024 ** 5 };
  const key = u.replace("B", "") as keyof typeof mult;
  const bytes = n * (mult[key] ?? 1);
  return { bytes, pretty: s };
}

function parseSfdiskDump(dump: string, loop: string) {
  // Defaults for dry-run or if dump unavailable
  if (!dump) {
    return {
      diskSectors: 0,
      boot: { start: 8192, end: 8192 + (256 * 1024 * 1024) / 512 - 1 },
      root: { start: 1050624, end: 0 }
    };
  }
  const boot = { start: 0, end: 0 };
  const root = { start: 0, end: 0 };
  const lines = dump.split("\n");
  const loopEscaped = loop.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  for (const line of lines) {
    const lp1 = line.match(new RegExp(`^${loopEscaped}p1\\s*:`));
    const lp2 = line.match(new RegExp(`^${loopEscaped}p2\\s*:`));
    if (lp1 || lp2) {
      const m = line.match(/start=\s*(\d+).+size=\s*(\d+)/);
      if (m) {
        const start = Number(m[1]);
        const size = Number(m[2]);
        const end = start + size - 1;
        if (lp1) { boot.start = start; boot.end = end; }
        if (lp2) { root.start = start; root.end = end; }
      }
    }
  }
  if (!boot.start || !root.start) throw new Error("Failed to parse partition table via sfdisk");
  // total disk sectors
  return { diskSectors: 0, boot, root };
}

function sfdiskTable(loop: string, p1Start: number, p1Size: number, p2Start: number, p2Size: number) {
  return `label: dos\nunit: sectors\n\n${loop}p1 : start=${p1Start}, size=${p1Size}, type=c, bootable\n${loop}p2 : start=${p2Start}, size=${p2Size}, type=83\n`;
}

async function rereadMappings(exe: Executor, loop: string) {
  await exe.run(["partprobe", loop], { allowNonZeroExit: true });
  await exe.run(["blockdev", "--rereadpt", loop], { allowNonZeroExit: true });
  await exe.run(["kpartx", "-dv", loop], { allowNonZeroExit: true });
  await exe.run(["kpartx", "-av", loop], { allowNonZeroExit: true });
  // Wait for device nodes to be ready
  await new Promise((resolve) => setTimeout(resolve, 1000));
}


if (import.meta.main) {
  const exe = new BunExecutor();
  run(exe).catch((e) => { console.error(e?.message || e); process.exit(1); });
}
