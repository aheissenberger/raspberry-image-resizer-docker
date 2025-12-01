import type { Executor } from "./executor";
import { DOCKERFILE, WORKER_JS } from "./embedded";
import { existsSync, mkdirSync } from "fs";
import { join } from "path";

export type DockerRunOptions = {
  image: string; // docker image name
  workdir: string; // host workdir to mount at /work
  env?: Record<string, string | number | boolean | undefined>;
  privileged?: boolean;
  entry?: string[]; // override entrypoint/cmd
};

/**
 * Check if Docker image exists, and build it from embedded resources if not
 */
export async function ensureImage(exe: Executor, image: string, contextDir?: string) {
  const inspect = await exe.run(["docker", "image", "inspect", image], { allowNonZeroExit: true });
  if (inspect.code === 0) return;

  // If contextDir provided (development mode), use it
  if (contextDir && existsSync(contextDir)) {
    console.log(`Building Docker image from ${contextDir}...`);
    await exe.run(["docker", "build", "-t", image, contextDir]);
    return;
  }

  // Otherwise, build from embedded resources (production mode)
  console.log(`Building Docker image (first run)...`);
  const tempDir = join("/tmp", `docker-build-${Date.now()}`);
  
  try {
    mkdirSync(tempDir, { recursive: true });
    
    // Write embedded resources
    await Bun.write(join(tempDir, "Dockerfile"), DOCKERFILE);
    await Bun.write(join(tempDir, "worker.js"), WORKER_JS);
    
    // Build image
    await exe.run(["docker", "build", "-t", image, tempDir]);
    console.log("✓ Docker image ready");
  } finally {
    // Cleanup temp directory
    try {
      await exe.run(["rm", "-rf", tempDir], { allowNonZeroExit: true });
    } catch {
      // Ignore cleanup errors
    }
  }
}

export async function runWorker(exe: Executor, opts: DockerRunOptions) {
  const args: string[] = ["docker", "run", "--rm"]; 
  if (opts.privileged ?? true) args.push("--privileged");
  args.push("-v", `${opts.workdir}:/work`);
  if (opts.env) {
    for (const [k, v] of Object.entries(opts.env)) {
      if (v === undefined) continue;
      args.push("-e", `${k}=${String(v)}`);
    }
  }
  args.push(opts.image);
  if (opts.entry && opts.entry.length) args.push(...opts.entry);
  return exe.run(args, { cwd: opts.workdir });
}
