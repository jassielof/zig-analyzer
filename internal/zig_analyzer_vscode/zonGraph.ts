/**
 * Lightweight `build.zig.zon` dependency scanning — the TypeScript mirror
 * of `src/lib/analysis/queries/packages.zig`'s `parseDependencies`, kept
 * in sync deliberately: both hand-scan rather than fully parse ZON, since
 * all that's needed is `.name = .{ .path = "…" }` / `.url = "…" .hash =
 * "…" }` entries, not a general-purpose ZON reader.
 */

/** One `.dependencies` entry, 0-based declaration line. */
export interface ZonDependency {
  name: string;
  line: number;
  /** Relative path, for a `.path`-based dependency. */
  path?: string;
  /** Package-cache hash, for a `.url`-based dependency. */
  hash?: string;
}

export function parseZonDependencies(source: string): ZonDependency[] {
  const depsKey = ".dependencies";
  const depsStart = source.indexOf(depsKey);
  if (depsStart === -1) return [];

  let i = depsStart + depsKey.length;
  while (i < source.length && /[\s=]/.test(source[i])) i++;
  if (source[i] !== ".") return [];
  if (source[i + 1] !== "{") return [];
  const bodyStart = i + 2;
  const bodyEnd = findMatchingBrace(source, bodyStart - 1);
  if (bodyEnd === null) return [];
  const body = source.slice(bodyStart, bodyEnd);

  const out: ZonDependency[] = [];
  let j = 0;
  while (j < body.length) {
    while (j < body.length) {
      const c = body[j];
      if (c === " " || c === "\t" || c === "\n" || c === "\r" || c === ",") {
        j++;
        continue;
      }
      if (c === "/" && body[j + 1] === "/") {
        while (j < body.length && body[j] !== "\n") j++;
        continue;
      }
      break;
    }
    if (j >= body.length) break;

    if (body[j] !== ".") {
      j++;
      continue;
    }
    j++;
    const nameStart = j;
    while (j < body.length && isIdentChar(body[j])) j++;
    if (j === nameStart) continue;
    const name = body.slice(nameStart, j);

    while (j < body.length && /[\s]/.test(body[j])) j++;
    if (body[j] !== "=") continue;
    j++;
    while (j < body.length && /[\s]/.test(body[j])) j++;
    if (body[j] !== "." || body[j + 1] !== "{") continue;
    const entryOpen = j + 1;
    const entryClose = findMatchingBrace(body, entryOpen);
    if (entryClose === null) break;
    const entry = body.slice(entryOpen + 1, entryClose);
    j = entryClose + 1;

    const path = extractQuotedField(entry, ".path");
    const hash = extractQuotedField(entry, ".hash");
    if (path === undefined && hash === undefined) continue;

    out.push({
      name,
      line: lineAt(source, bodyStart + nameStart),
      path,
      hash,
    });
  }
  return out;
}

function extractQuotedField(entry: string, key: string): string | undefined {
  const idx = entry.indexOf(key);
  if (idx === -1) return undefined;
  let i = idx + key.length;
  while (i < entry.length && /[\s=]/.test(entry[i])) i++;
  if (entry[i] !== '"') return undefined;
  i++;
  const start = i;
  while (i < entry.length && entry[i] !== '"') i++;
  if (i >= entry.length) return undefined;
  return entry.slice(start, i);
}

function findMatchingBrace(source: string, openIndex: number): number | null {
  if (source[openIndex] !== "{") return null;
  let depth = 0;
  let inString = false;
  for (let i = openIndex; i < source.length; i++) {
    const c = source[i];
    if (inString) {
      if (c === "\\" && i + 1 < source.length) {
        i++;
        continue;
      }
      if (c === '"') inString = false;
      continue;
    }
    if (c === '"') inString = true;
    else if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth === 0) return i;
    }
  }
  return null;
}

function isIdentChar(c: string): boolean {
  return /[A-Za-z0-9_]/.test(c);
}

function lineAt(source: string, offset: number): number {
  let line = 0;
  for (let i = 0; i < offset && i < source.length; i++) {
    if (source[i] === "\n") line++;
  }
  return line;
}

/** Extracts `.version = "…"` from a `build.zig.zon`'s top level. */
export function parseZonVersion(source: string): string | undefined {
  const match = /\.version\s*=\s*"([^"]*)"/.exec(source);
  return match?.[1];
}

/**
 * Extracts `.<field> = "…"` from `zig env`'s ZON-flavored output (not
 * JSON — see `Server.discoverZigLibDir` in src/lib/server.zig, which
 * parses the same output with `std.zon.parse`). Unescapes the common
 * cases ZON string literals use for path separators on Windows.
 */
export function parseZigEnvField(
  envOutput: string,
  field: string,
): string | undefined {
  const re = new RegExp(`\\.${field}\\s*=\\s*"((?:[^"\\\\]|\\\\.)*)"`);
  const match = re.exec(envOutput);
  if (!match) return undefined;
  return match[1].replace(/\\(.)/g, "$1");
}
