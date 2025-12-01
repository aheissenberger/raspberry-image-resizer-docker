import { describe, it, expect } from "bun:test";
import { normalizeDevice } from "../src/lib/devices";

describe("normalizeDevice", () => {
  it("accepts /dev/diskN and returns both forms", () => {
    const n = normalizeDevice("/dev/disk2");
    expect(n.disk).toBe("/dev/disk2");
    expect(n.rdisk).toBe("/dev/rdisk2");
  });

  it("accepts /dev/rdiskN and returns both forms", () => {
    const n = normalizeDevice("/dev/rdisk3");
    expect(n.disk).toBe("/dev/disk3");
    expect(n.rdisk).toBe("/dev/rdisk3");
  });

  it("rejects invalid formats", () => {
    expect(() => normalizeDevice("/dev/disk")).toThrow();
    expect(() => normalizeDevice("disk2")).toThrow();
    expect(() => normalizeDevice("/dev/sda")).toThrow();
  });
});
