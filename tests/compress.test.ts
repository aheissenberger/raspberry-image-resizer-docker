import { describe, it, expect } from "bun:test";
import { detectCompressionByExt, validateLevel, buildCompressor, buildDecompressor } from "../src/lib/compress";

describe("compression utils", () => {
  it("detects by extension", () => {
    expect(detectCompressionByExt("foo.img")).toBeNull();
    expect(detectCompressionByExt("foo.img.zst")).toBe("zstd");
    expect(detectCompressionByExt("foo.img.xz")).toBe("xz");
    expect(detectCompressionByExt("foo.img.gz")).toBe("gzip");
  });
  it("validates levels", () => {
    expect(() => validateLevel("zstd", 20)).toThrow();
    expect(() => validateLevel("xz", 10)).toThrow();
    expect(() => validateLevel("gzip", 0)).toThrow();
    expect(() => validateLevel("zstd", 5)).not.toThrow();
  });
  it("builds commands", () => {
    expect(buildCompressor("zstd", 3)[0]).toBe("zstd");
    expect(buildDecompressor("xz")[0]).toBe("xz");
  });
});
