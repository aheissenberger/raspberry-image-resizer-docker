export type ArgSpec = { name: string; type: "string" | "boolean" | "number"; alias?: string; default?: any };

export function parseArgs(argv: string[], specs: ArgSpec[]) {
  const map = new Map<string, ArgSpec>();
  for (const s of specs) {
    map.set(`--${s.name}`, s);
    if (s.alias) map.set(`-${s.alias}`, s);
  }
  const result: Record<string, any> = {};
  for (const s of specs) {
    if (s.default !== undefined) result[s.name] = s.default;
  }
  const positional: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (!tok.startsWith('-')) { positional.push(tok); continue; }
    const spec = map.get(tok);
    if (!spec) throw new Error(`Unknown argument: ${tok}`);
    if (spec.type === 'boolean') {
      result[spec.name] = true;
    } else {
      const val = argv[++i];
      if (val === undefined) throw new Error(`Missing value for ${tok}`);
      result[spec.name] = spec.type === 'number' ? Number(val) : val;
    }
  }
  return { args: result, positional };
}
