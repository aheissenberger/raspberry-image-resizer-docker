export type ExecOptions = {
  cwd?: string;
  env?: Record<string, string | undefined>;
  timeoutMs?: number;
  stdin?: string | Uint8Array;
  onStdoutChunk?: (chunk: string) => void;
  onStderrChunk?: (chunk: string) => void;
  allowNonZeroExit?: boolean;
};

export type ExecResult = {
  code: number;
  stdout: string;
  stderr: string;
};

export interface Executor {
  run(cmd: string[], options?: ExecOptions): Promise<ExecResult>;
}

export class BunExecutor implements Executor {
  async run(cmd: string[], options: ExecOptions = {}): Promise<ExecResult> {
    const { cwd, env, timeoutMs, stdin, onStdoutChunk, onStderrChunk, allowNonZeroExit } = options;

    const proc = Bun.spawn(cmd, {
      cwd,
      env: env as Record<string, string>,
      stdin: stdin ? "pipe" : "inherit",
      stdout: "pipe",
      stderr: "pipe",
    });

    const stdoutChunks: string[] = [];
    const stderrChunks: string[] = [];

    // Stream stdout/stderr
    const readStream = async (stream: ReadableStream<Uint8Array> | null, onChunk?: (s: string) => void, sink: string[] = []) => {
      if (!stream) return;
      const reader = stream.getReader();
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const text = new TextDecoder().decode(value);
        sink.push(text);
        if (onChunk) onChunk(text);
      }
    };

    const tasks: Promise<any>[] = [];
    tasks.push(readStream(proc.stdout, onStdoutChunk, stdoutChunks));
    tasks.push(readStream(proc.stderr, onStderrChunk, stderrChunks));

    // Write stdin if provided
    if (stdin && proc.stdin) {
      const data = typeof stdin === "string" ? new TextEncoder().encode(stdin) : stdin;
      proc.stdin.write(data);
      proc.stdin.end();
    }

    let timedOut = false;
    let timeoutHandle: Timer | undefined;
    const wait = proc.exited;

    if (timeoutMs && timeoutMs > 0) {
      const timeoutPromise = new Promise<void>((resolve) => {
        timeoutHandle = setTimeout(() => {
          timedOut = true;
          try { proc.kill(); } catch {}
          resolve();
        }, timeoutMs) as unknown as Timer;
      });
      await Promise.race([wait, timeoutPromise]);
    } else {
      await wait;
    }

    if (timeoutHandle) clearTimeout(timeoutHandle as any);

    await Promise.all(tasks);

    const result: ExecResult = {
      code: proc.exitCode ?? (timedOut ? 124 : 1),
      stdout: stdoutChunks.join(""),
      stderr: stderrChunks.join(""),
    };

    if (timedOut) {
      throw new Error(`Command timed out: ${cmd.join(" ")}`);
    }

    if (result.code !== 0 && !allowNonZeroExit) {
      const err = new Error(`Command failed (${result.code}): ${cmd.join(" ")}\n${result.stderr}`);
      // Attach result for callers that need more detail
      (err as any).result = result;
      throw err;
    }

    return result;
  }
}

export type RecordedCall = { cmd: string[]; options?: ExecOptions; result?: ExecResult };

export class RecordingExecutor implements Executor {
  public calls: RecordedCall[] = [];
  constructor(private responses: ((cmd: string[]) => ExecResult | Promise<ExecResult>) | ExecResult = { code: 0, stdout: "", stderr: "" }) {}
  async run(cmd: string[], options?: ExecOptions): Promise<ExecResult> {
    const res = typeof this.responses === "function" ? await (this.responses as any)(cmd) : this.responses;
    const copy: ExecResult = { code: res.code, stdout: res.stdout, stderr: res.stderr };
    this.calls.push({ cmd: [...cmd], options, result: copy });
    if (copy.code !== 0 && !(options?.allowNonZeroExit)) {
      const err = new Error(`Command failed (${copy.code}): ${cmd.join(" ")}`);
      (err as any).result = copy;
      throw err;
    }
    return copy;
  }
}
