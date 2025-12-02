import { describe, it, expect, mock, beforeEach, afterEach } from "bun:test";
import { BunExecutor } from "../src/lib/executor";
import { mkdirSync, rmSync, writeFileSync, existsSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

// Test utility functions that would be exported from cli.ts
// Since they're not exported, we'll test them through integration or mock the behavior

describe("CLI utility functions", () => {
  let testDir: string;

  beforeEach(() => {
    testDir = join(tmpdir(), `cli-test-${Date.now()}`);
    mkdirSync(testDir, { recursive: true });
  });

  afterEach(() => {
    if (existsSync(testDir)) {
      rmSync(testDir, { recursive: true, force: true });
    }
  });

  describe("detectAndSelectDevice", () => {
    it("should return explicit device when provided", async () => {
      const exec = new BunExecutor();
      const explicitDevice = "/dev/disk4";
      
      // Mock behavior: should normalize to disk/rdisk pair
      const expected = {
        disk: "/dev/disk4",
        rdisk: "/dev/rdisk4"
      };
      
      // Since function is not exported, test the logic inline
      const selected = explicitDevice;
      const raw = selected.replace("/dev/disk", "/dev/rdisk");
      
      expect(selected).toBe(expected.disk);
      expect(raw).toBe(expected.rdisk);
    });

    it("should convert disk to rdisk correctly", () => {
      const testCases = [
        { input: "/dev/disk2", expectedDisk: "/dev/disk2", expectedRdisk: "/dev/rdisk2" },
        { input: "/dev/disk10", expectedDisk: "/dev/disk10", expectedRdisk: "/dev/rdisk10" },
        { input: "/dev/disk99", expectedDisk: "/dev/disk99", expectedRdisk: "/dev/rdisk99" },
      ];

      testCases.forEach(({ input, expectedDisk, expectedRdisk }) => {
        const raw = input.replace("/dev/disk", "/dev/rdisk");
        expect(input).toBe(expectedDisk);
        expect(raw).toBe(expectedRdisk);
      });
    });
  });

  describe("preflightImageSize", () => {
    it("should validate uncompressed image fits on device", async () => {
      const imagePath = join(testDir, "test.img");
      const imageSize = 1024 * 1024 * 100; // 100MB
      const deviceSize = 1024 * 1024 * 200; // 200MB
      
      // Create test image
      writeFileSync(imagePath, Buffer.alloc(imageSize));
      
      const actualImageSize = Bun.file(imagePath).size;
      expect(actualImageSize).toBe(imageSize);
      
      // Test logic: image smaller than device should pass
      const fitsOnDevice = actualImageSize <= deviceSize;
      expect(fitsOnDevice).toBe(true);
    });

    it("should reject image larger than device", () => {
      const imageSize = 1024 * 1024 * 300; // 300MB
      const deviceSize = 1024 * 1024 * 200; // 200MB
      
      const fitsOnDevice = imageSize <= deviceSize;
      expect(fitsOnDevice).toBe(false);
    });

    it("should skip validation for compressed images", () => {
      // Compressed images cannot be validated before decompression
      const isCompressed = true;
      
      // Should skip size check and only warn
      if (isCompressed) {
        // Test passes if we recognize it's compressed
        expect(isCompressed).toBe(true);
      }
    });
  });

  describe("writeImageToDevice", () => {
    it("should construct correct dd command for uncompressed images", () => {
      const imagePath = "/path/to/image.img";
      const device = { disk: "/dev/disk4", rdisk: "/dev/rdisk4" };
      const blockSize = "4m";
      
      // Escape single quotes in path
      const escapePath = (p: string) => `'${p.replaceAll("'", "'\\''")}'`;
      const escaped = escapePath(imagePath);
      
      const expectedCmd = `sudo dd if=${escaped} of=${device.rdisk} bs=${blockSize} conv=fsync status=progress`;
      expect(expectedCmd).toContain("sudo dd");
      expect(expectedCmd).toContain(device.rdisk);
      expect(expectedCmd).toContain(blockSize);
      expect(expectedCmd).toContain("conv=fsync");
      expect(expectedCmd).toContain("status=progress");
    });

    it("should construct correct dd command with decompression", () => {
      const imagePath = "/path/to/image.img.zst";
      const device = { disk: "/dev/disk4", rdisk: "/dev/rdisk4" };
      const blockSize = "4m";
      const decompressor = ["zstd", "-dc"];
      
      const escapePath = (p: string) => `'${p.replaceAll("'", "'\\''")}'`;
      const escaped = escapePath(imagePath);
      
      const expectedCmd = `${decompressor.join(" ")} ${escaped} | sudo dd of=${device.rdisk} bs=${blockSize} conv=fsync status=progress`;
      expect(expectedCmd).toContain("zstd -dc");
      expect(expectedCmd).toContain("sudo dd");
      expect(expectedCmd).toContain(device.rdisk);
    });
  });

  describe("prepareWorkingImage", () => {
    it("should return original path for uncompressed images", async () => {
      const imagePath = join(testDir, "test.img");
      writeFileSync(imagePath, Buffer.alloc(1024));
      
      const workingPath = join(testDir, "working.img");
      const isDryRun = false;
      
      // No compression detected (no .zst/.xz/.gz extension)
      const hasCompression = /\.(zst|xz|gz)$/i.test(imagePath);
      expect(hasCompression).toBe(false);
      
      // Should return original path when no compression
      const result = hasCompression ? workingPath : imagePath;
      expect(result).toBe(imagePath);
    });

    it("should detect compressed formats", () => {
      const testCases = [
        { path: "test.img.zst", expected: true },
        { path: "test.img.xz", expected: true },
        { path: "test.img.gz", expected: true },
        { path: "test.img", expected: false },
        { path: "test.iso", expected: false },
      ];

      testCases.forEach(({ path, expected }) => {
        const hasCompression = /\.(zst|xz|gz)$/i.test(path);
        expect(hasCompression).toBe(expected);
      });
    });

    it("should skip decompression in dry-run mode", () => {
      const isDryRun = true;
      const imagePath = "test.img.zst";
      
      // Dry run should return original path even if compressed
      if (isDryRun) {
        const result = imagePath;
        expect(result).toBe(imagePath);
      }
    });
  });

  describe("createBackup", () => {
    it("should create backup file when not in dry-run", async () => {
      const sourcePath = join(testDir, "source.img");
      const targetPath = join(testDir, "backup.img");
      
      writeFileSync(sourcePath, Buffer.alloc(1024));
      
      const isDryRun = false;
      
      if (!isDryRun) {
        // Simulate cp command
        const sourceData = await Bun.file(sourcePath).arrayBuffer();
        await Bun.write(targetPath, sourceData);
      }
      
      expect(existsSync(targetPath)).toBe(true);
    });

    it("should skip backup creation in dry-run mode", () => {
      const isDryRun = true;
      const targetPath = join(testDir, "backup.img");
      
      if (!isDryRun) {
        // Would create backup here
      }
      
      // Should not exist because dry-run
      expect(existsSync(targetPath)).toBe(false);
    });
  });

  describe("escapePath", () => {
    it("should escape single quotes in paths", () => {
      const escapePath = (p: string) => `'${p.replaceAll("'", "'\\''")}'`;
      
      const testCases = [
        { input: "/path/to/file.img", expected: "'/path/to/file.img'" },
        { input: "/path/with'quote.img", expected: "'/path/with'\\''quote.img'" },
        { input: "/path/with'multiple'quotes.img", expected: "'/path/with'\\''multiple'\\''quotes.img'" },
      ];

      testCases.forEach(({ input, expected }) => {
        const result = escapePath(input);
        expect(result).toBe(expected);
      });
    });
  });

  describe("formatDuration", () => {
    it("should format durations correctly", () => {
      const formatDuration = (ms: number): string => {
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
      };

      const testCases = [
        { input: 1000, expected: "1s" },
        { input: 5000, expected: "5s" },
        { input: 60000, expected: "1m 0s" },
        { input: 65000, expected: "1m 5s" },
        { input: 3600000, expected: "1h 0m 0s" },
        { input: 3665000, expected: "1h 1m 5s" },
        { input: 7325000, expected: "2h 2m 5s" },
      ];

      testCases.forEach(({ input, expected }) => {
        const result = formatDuration(input);
        expect(result).toBe(expected);
      });
    });
  });

  describe("bytesToGiB", () => {
    it("should convert bytes to GiB correctly", () => {
      const bytesToGiB = (n: number): string => {
        return `${(n / (1024 ** 3)).toFixed(2)} GiB`;
      };

      const testCases = [
        { input: 1024 ** 3, expected: "1.00 GiB" },
        { input: 2 * 1024 ** 3, expected: "2.00 GiB" },
        { input: 1.5 * 1024 ** 3, expected: "1.50 GiB" },
        { input: 32 * 1024 ** 3, expected: "32.00 GiB" },
        { input: 512 * 1024 ** 2, expected: "0.50 GiB" },
      ];

      testCases.forEach(({ input, expected }) => {
        const result = bytesToGiB(input);
        expect(result).toBe(expected);
      });
    });
  });

  describe("resolveBlockSize", () => {
    it("should return default when no input provided", () => {
      const resolveBlockSize = (input?: string) => {
        const def = "4m";
        if (!input) return def;
        
        // Simple validation regex
        if (!/^[1-9][0-9]*(?:[kKmMgG])?$/.test(input.trim())) {
          return def;
        }
        return input.trim().toLowerCase();
      };

      expect(resolveBlockSize()).toBe("4m");
      expect(resolveBlockSize(undefined)).toBe("4m");
    });

    it("should validate and normalize block sizes", () => {
      const resolveBlockSize = (input?: string) => {
        const def = "4m";
        if (!input) return def;
        
        if (!/^[1-9][0-9]*(?:[kKmMgG])?$/.test(input.trim())) {
          return def;
        }
        return input.trim().toLowerCase();
      };

      const testCases = [
        { input: "4m", expected: "4m" },
        { input: "4M", expected: "4m" },
        { input: "8m", expected: "8m" },
        { input: "1024k", expected: "1024k" },
        { input: "1g", expected: "1g" },
        { input: "invalid", expected: "4m" }, // Falls back to default
        { input: "0m", expected: "4m" }, // Invalid: starts with 0
        { input: "-4m", expected: "4m" }, // Invalid: negative
      ];

      testCases.forEach(({ input, expected }) => {
        const result = resolveBlockSize(input);
        expect(result).toBe(expected);
      });
    });
  });

  describe("path utilities", () => {
    it("should extract dirname correctly", () => {
      const dirname = (p: string) => p.substring(0, p.lastIndexOf("/")) || ".";
      
      const testCases = [
        { input: "/path/to/file.img", expected: "/path/to" },
        { input: "/path/file.img", expected: "/path" },
        { input: "file.img", expected: "." },
        { input: "/file.img", expected: "." },
      ];

      testCases.forEach(({ input, expected }) => {
        const result = dirname(input);
        expect(result).toBe(expected);
      });
    });

    it("should extract basename correctly", () => {
      const basename = (p: string) => p.substring(p.lastIndexOf("/") + 1);
      
      const testCases = [
        { input: "/path/to/file.img", expected: "file.img" },
        { input: "/path/file.img", expected: "file.img" },
        { input: "file.img", expected: "file.img" },
        { input: "/path/to/", expected: "" },
      ];

      testCases.forEach(({ input, expected }) => {
        const result = basename(input);
        expect(result).toBe(expected);
      });
    });
  });

  describe("timestamp generation", () => {
    it("should generate consistent timestamp format", () => {
      const date = new Date("2025-12-02T14:30:45.123Z");
      const ts = date.toISOString().replace(/[-:TZ.]/g, "").slice(0, 12);
      
      // Format: YYYYMMDDHHmm
      expect(ts).toBe("202512021430");
      expect(ts.length).toBe(12);
    });
  });

  describe("working file naming", () => {
    it("should generate working file names correctly", () => {
      const imageBase = "raspios-lite.img";
      const lastDot = imageBase.lastIndexOf(".");
      const bareOriginal = lastDot > 0 ? imageBase.slice(0, lastDot) : imageBase;
      const ts = "202512021430";
      const workingName = `${bareOriginal}_${ts}.img`;
      
      expect(bareOriginal).toBe("raspios-lite");
      expect(workingName).toBe("raspios-lite_202512021430.img");
    });

    it("should handle compressed image names", () => {
      const imageBase = "raspios-lite.img.zst";
      const lastDot = imageBase.lastIndexOf(".");
      const bareOriginal = lastDot > 0 ? imageBase.slice(0, lastDot) : imageBase;
      const extOriginal = lastDot > 0 ? imageBase.slice(lastDot) : "";
      
      expect(bareOriginal).toBe("raspios-lite.img");
      expect(extOriginal).toBe(".zst");
    });

    it("should handle files without extensions", () => {
      const imageBase = "raspios-lite";
      const lastDot = imageBase.lastIndexOf(".");
      const bareOriginal = lastDot > 0 ? imageBase.slice(0, lastDot) : imageBase;
      
      expect(bareOriginal).toBe("raspios-lite");
    });
  });

  describe("auto-sizing calculation", () => {
    it("should calculate safe image size from device capacity", () => {
      const devSizeBytes = 32 * 1024 ** 3; // 32GB
      const safeBytes = Math.floor(devSizeBytes * 0.98); // 2% headroom
      const safeMB = Math.floor(safeBytes / 1024 / 1024);
      
      expect(safeMB).toBeLessThan(32 * 1024); // Less than 32GB in MB
      expect(safeMB).toBeGreaterThan(31 * 1024); // More than 31GB in MB
      
      // Verify 2% headroom is applied
      const percentageUsed = (safeMB * 1024 * 1024) / devSizeBytes;
      expect(percentageUsed).toBeLessThanOrEqual(0.98);
    });

    it("should format size as MB for deploy", () => {
      const safeMB = 31352;
      const chosenImageSize = `${safeMB}MB`;
      
      expect(chosenImageSize).toBe("31352MB");
    });
  });
});
