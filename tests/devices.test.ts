import { describe, it, expect } from "bun:test";
import { parseDiskutilListDevices, isRemovableInfo, hasBootFatPartition, detectPiDisk, detectRemovableDisk } from "../src/lib/devices";
import { RecordingExecutor, type ExecResult } from "../src/lib/executor";

const sampleDiskutilList = `
/dev/disk0 (internal, physical):
   #:                        TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.3 GB   disk0
   1:                        EFI EFI                     314.6 MB   disk0s1
/dev/disk2 (external, physical):
   #:                        TYPE NAME                    SIZE       IDENTIFIER
   0:     FDisk_partition_scheme                        *32.0 GB    disk2
   1:             Windows_FAT_32 boot                     268.4 MB   disk2s1
   2:                  Linux Filesystem                   31.7 GB    disk2s2
`;

const sampleInfoInternal = `
   Device Identifier:        disk0
   Device Node:              /dev/disk0
   Removable Media:          Fixed
`;

const sampleInfoExternal = `
   Device Identifier:        disk2
   Device Node:              /dev/disk2
   Removable Media:          Removable
`;

const sampleListDisk2 = `
/dev/disk2 (external, physical):
   #:                        TYPE NAME                    SIZE       IDENTIFIER
   0:     FDisk_partition_scheme                        *32.0 GB    disk2
   1:             Windows_FAT_32 boot                     268.4 MB   disk2s1
   2:                  Linux Filesystem                   31.7 GB    disk2s2
`;

const sampleListDisk0 = `
/dev/disk0 (internal, physical):
   #:                        TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.3 GB   disk0
   1:                        EFI EFI                     314.6 MB   disk0s1
`;

describe("devices parse helpers", () => {
  it("extracts device nodes from diskutil list", () => {
    const devs = parseDiskutilListDevices(sampleDiskutilList);
    expect(devs).toEqual(["/dev/disk0", "/dev/disk2"]);
  });

  it("detects removable from info", () => {
    expect(isRemovableInfo(sampleInfoInternal)).toBe(false);
    expect(isRemovableInfo(sampleInfoExternal)).toBe(true);
  });

  it("detects boot FAT partition", () => {
    expect(hasBootFatPartition(sampleListDisk2)).toBe(true);
    expect(hasBootFatPartition(sampleListDisk0)).toBe(false);
  });
});

describe("detectPiDisk / detectRemovableDisk (mocked)", () => {
  it("returns the external removable with boot FAT for Pi", async () => {
    const responder = (cmd: string[]): ExecResult => {
      const s = (stdout: string): ExecResult => ({ code: 0, stdout, stderr: "" });
      if (cmd[0] === "diskutil" && cmd[1] === "list" && cmd.length === 2) return s(sampleDiskutilList);
      if (cmd[0] === "diskutil" && cmd[1] === "info" && cmd[2] === "/dev/disk0") return s(sampleInfoInternal);
      if (cmd[0] === "diskutil" && cmd[1] === "info" && cmd[2] === "/dev/disk2") return s(sampleInfoExternal);
      if (cmd[0] === "diskutil" && cmd[1] === "list" && cmd[2] === "/dev/disk2") return s(sampleListDisk2);
      if (cmd[0] === "diskutil" && cmd[1] === "list" && cmd[2] === "/dev/disk0") return s(sampleListDisk0);
      return { code: 1, stdout: "", stderr: "unexpected command" };
    };
    const exec = new RecordingExecutor(responder);
    const d = await detectPiDisk(exec);
    expect(d).toBe("/dev/disk2");
  });

  it("returns first removable device for generic removable", async () => {
    const responder = (cmd: string[]): ExecResult => {
      const s = (stdout: string): ExecResult => ({ code: 0, stdout, stderr: "" });
      if (cmd[0] === "diskutil" && cmd[1] === "list" && cmd.length === 2) return s(sampleDiskutilList);
      if (cmd[0] === "diskutil" && cmd[1] === "info" && cmd[2] === "/dev/disk0") return s(sampleInfoInternal);
      if (cmd[0] === "diskutil" && cmd[1] === "info" && cmd[2] === "/dev/disk2") return s(sampleInfoExternal);
      return { code: 1, stdout: "", stderr: "unexpected command" };
    };
    const exec = new RecordingExecutor(responder);
    const d = await detectRemovableDisk(exec);
    expect(d).toBe("/dev/disk2");
  });
});
