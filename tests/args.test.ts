import { describe, it, expect } from "bun:test";
import { parseArgs } from "../src/lib/args";

describe("args parser", () => {
  it("parses flags and positionals", () => {
    const { args, positional } = parseArgs(["--foo", "bar", "-n", "3", "pos1", "pos2"], [
      { name: "foo", type: "string" },
      { name: "n", type: "number", alias: "n" },
    ]);
    expect(args.foo).toBe("bar");
    expect(args.n).toBe(3);
    expect(positional).toEqual(["pos1", "pos2"]);
  });
});
