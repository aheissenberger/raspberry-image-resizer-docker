export function resolveBlockSize(input?: string) {
  const def = "4m";
  if (!input) return def;
  const v = String(input).trim();
  if (/^[1-9][0-9]*(?:[kKmMgG])?$/.test(v)) return v.toLowerCase();
  return def;
}

export function buildCloneDdCommand(params: {
  rawDevice: string;
  outputPath: string;
  blockSize: string;
  compressor?: string[];
}): string {
  const { rawDevice, outputPath, blockSize, compressor } = params;
  if (compressor && compressor.length) {
    return `sudo dd if=${rawDevice} bs=${blockSize} conv=sync,noerror status=progress 2>/dev/stderr | ${compressor.join(" ")} > ${outputPath}`;
  }
  return `sudo dd if=${rawDevice} of=${outputPath} bs=${blockSize} conv=sync,noerror status=progress`;
}

export function buildWriteDdCommand(params: {
  rawDevice: string;
  imagePath: string;
  blockSize: string;
  decompressor?: string[];
}): string {
  const { rawDevice, imagePath, blockSize, decompressor } = params;
  if (decompressor && decompressor.length) {
    return `${decompressor.join(" ")} ${imagePath} | sudo dd of=${rawDevice} bs=${blockSize} status=progress 2>/dev/stderr`;
  }
  return `sudo dd if=${imagePath} of=${rawDevice} bs=${blockSize} status=progress`;
}
