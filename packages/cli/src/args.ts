export interface ParsedArgs {
  command: string | undefined;
  flags: Record<string, string>;
}

/** Minimal `--flag value` parser. No external dependency needed for this CLI's scope. */
export function parseArgs(argv: string[]): ParsedArgs {
  const [command, ...rest] = argv;
  const flags: Record<string, string> = {};
  for (let i = 0; i < rest.length; i += 1) {
    const token = rest[i];
    if (token?.startsWith("--")) {
      const key = token.slice(2);
      const value = rest[i + 1];
      if (value !== undefined && !value.startsWith("--")) {
        flags[key] = value;
        i += 1;
      } else {
        flags[key] = "true";
      }
    }
  }
  return { command, flags };
}

export function requireFlag(flags: Record<string, string>, name: string): string {
  const value = flags[name];
  if (!value) {
    throw new Error(`Missing required flag --${name}`);
  }
  return value;
}
