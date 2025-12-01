export type CompressAlgo = "zstd" | "xz" | "gzip";

export function detectCompressionByExt(path: string): CompressAlgo | null {
  if (path.endsWith('.zst')) return 'zstd';
  if (path.endsWith('.xz')) return 'xz';
  if (path.endsWith('.gz')) return 'gzip';
  return null;
}

export function buildCompressor(algo: CompressAlgo, level?: number): string[] {
  switch (algo) {
    case 'zstd': return ["zstd", `-${level ?? 3}`, "-T0"]; // multithreaded
    case 'xz':   return ["xz", `-${level ?? 6}`, "-T0"];   // multithreaded
    case 'gzip': return ["gzip", `-${level ?? 6}`];
  }
}

export function buildDecompressor(algo: CompressAlgo): string[] {
  switch (algo) {
    case 'zstd': return ["zstd", "-dc"]; 
    case 'xz':   return ["xz", "-dc"];   
    case 'gzip': return ["gzip", "-dc"]; 
  }
}

export function validateLevel(algo: CompressAlgo, level?: number) {
  if (level === undefined) return;
  if (!Number.isFinite(level)) throw new Error(`Invalid compression level: ${level}`);
  if (algo === 'zstd') {
    if (level < 1 || level > 19) throw new Error('zstd level must be 1-19');
  } else {
    if (level < 1 || level > 9) throw new Error(`${algo} level must be 1-9`);
  }
}
