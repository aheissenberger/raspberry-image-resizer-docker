import type { Executor } from "./executor";

export function parseDiskutilListDevices(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.startsWith("/dev/disk") && /\/dev\/disk\d+/.test(l))
    .map((l) => l.split(/\s+/)[0]);
}

export function isRemovableInfo(infoText: string): boolean {
  const line = infoText
    .split(/\r?\n/)
    .map((l) => l.trim())
    .find((l) => l.toLowerCase().startsWith("removable media:"));
  if (!line) return false;
  return /removable\s*$/i.test(line);
}

export function hasBootFatPartition(listText: string): boolean {
  // Look for FAT32 partition with name 'boot' (common on Raspberry Pi)
  // diskutil formats partition lines with TYPE and NAME; FAT often shown as Windows_FAT_32
  return /Windows_FAT_32.*\bboot\b/i.test(listText);
}

export async function detectPiDisk(exec: Executor): Promise<string | undefined> {
  const list = await exec.run(["diskutil", "list"]);
  const devices = parseDiskutilListDevices(list.stdout);
  for (const d of devices) {
    const info = await exec.run(["diskutil", "info", d], { allowNonZeroExit: true });
    if (!isRemovableInfo(info.stdout)) continue;
    const dl = await exec.run(["diskutil", "list", d], { allowNonZeroExit: true });
    if (hasBootFatPartition(dl.stdout)) return d;
  }
  return undefined;
}

export async function detectRemovableDisk(exec: Executor): Promise<string | undefined> {
  const list = await exec.run(["diskutil", "list"]);
  const devices = parseDiskutilListDevices(list.stdout);
  for (const d of devices) {
    const info = await exec.run(["diskutil", "info", d], { allowNonZeroExit: true });
    if (isRemovableInfo(info.stdout)) return d;
  }
  return undefined;
}

export function normalizeDevice(input: string): { disk: string; rdisk: string } {
  const t = input.trim();
  if (!t.startsWith("/dev/disk") && !t.startsWith("/dev/rdisk")) {
    throw new Error(`Invalid device path: ${input}`);
  }
  const n = t.replace("/dev/rdisk", "/dev/disk");
  if (!/^\/dev\/disk\d+$/.test(n)) {
    throw new Error(`Unsupported device format: ${input}`);
  }
  return { disk: n, rdisk: n.replace("/dev/disk", "/dev/rdisk") };
}
