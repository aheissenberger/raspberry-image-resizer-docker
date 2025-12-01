import { describe, it, expect } from "bun:test";
import { RecordingExecutor } from "../src/lib/executor";
import { runWorker } from "../src/lib/docker";

describe("docker wrapper", () => {
  it("builds docker run arguments", async () => {
    const rec = new RecordingExecutor({ code: 0, stdout: "", stderr: "" });
    await runWorker(rec, { image: "img:latest", workdir: "/tmp", env: { A: "1", B: "two" } });
    const call = rec.calls[0];
    expect(call.cmd[0]).toBe("docker");
    expect(call.cmd.includes("-v")).toBeTruthy();
    expect(call.cmd.includes("img:latest")).toBeTruthy();
  });
});
