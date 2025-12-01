import type { Executor } from "./executor";

export type DockerRunOptions = {
  image: string; // docker image name
  workdir: string; // host workdir to mount at /work
  env?: Record<string, string | number | boolean | undefined>;
  privileged?: boolean;
  entry?: string[]; // override entrypoint/cmd
};

export async function ensureImage(exe: Executor, image: string, contextDir: string) {
  const inspect = await exe.run(["docker", "image", "inspect", image], { allowNonZeroExit: true });
  if (inspect.code === 0) return;
  await exe.run(["docker", "build", "-t", image, contextDir]);
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
