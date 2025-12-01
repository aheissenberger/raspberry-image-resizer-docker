import { describe, it, expect } from "bun:test";
import { resolveBlockSize, buildCloneDdCommand, buildWriteDdCommand } from "../src/lib/dd";

describe("resolveBlockSize", () => {
  it("returns default 4m when undefined", () => {
    expect(resolveBlockSize(undefined)).toBe("4m");
  });

  it("normalizes unit case to lowercase", () => {
    expect(resolveBlockSize("4M")).toBe("4m");
    expect(resolveBlockSize("8K")).toBe("8k");
    expect(resolveBlockSize("1G")).toBe("1g");
  });

  it("accepts plain numbers and with suffix k/m/g", () => {
    expect(resolveBlockSize("512k")).toBe("512k");
    expect(resolveBlockSize("2m")).toBe("2m");
    expect(resolveBlockSize("1g")).toBe("1g");
    expect(resolveBlockSize("1024")).toBe("1024");
  });

  it("falls back to default for invalid values", () => {
    expect(resolveBlockSize("0m")).toBe("4m");
    expect(resolveBlockSize("-1m")).toBe("4m");
    expect(resolveBlockSize("abc")).toBe("4m");
    expect(resolveBlockSize("  ")).toBe("4m");
  });
});

describe("buildCloneDdCommand", () => {
  const raw = "/dev/rdisk2";
  const out = "/tmp/out.img";

  it("builds dd command without compression", () => {
    const cmd = buildCloneDdCommand({ rawDevice: raw, outputPath: out, blockSize: "4m" });
    expect(cmd).toBe(
      `sudo dd if=${raw} of=${out} bs=4m conv=sync,noerror status=progress`
    );
  });

  it("builds dd pipeline with compression", () => {
    const cmd = buildCloneDdCommand({ rawDevice: raw, outputPath: out, blockSize: "4m", compressor: ["zstd", "-3"] });
    expect(cmd).toBe(
      `sudo dd if=${raw} bs=4m conv=sync,noerror status=progress 2>/dev/stderr | zstd -3 > ${out}`
    );
  });
});

describe("buildWriteDdCommand", () => {
  const raw = "/dev/rdisk2";
  const img = "/tmp/in.img";

  it("builds dd command without decompression", () => {
    const cmd = buildWriteDdCommand({ rawDevice: raw, imagePath: img, blockSize: "2m" });
    expect(cmd).toBe(
      `sudo dd if=${img} of=${raw} bs=2m status=progress`
    );
  });

  it("builds dd pipeline with decompression", () => {
    const cmd = buildWriteDdCommand({ rawDevice: raw, imagePath: img, blockSize: "4m", decompressor: ["xz", "-d", "-c"] });
    expect(cmd).toBe(
      `xz -d -c ${img} | sudo dd of=${raw} bs=4m status=progress 2>/dev/stderr`
    );
  });
});
