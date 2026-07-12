import { execFile } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { promisify } from "node:util";
import * as vscode from "vscode";
import { parseZigEnvField, parseZonDependencies, parseZonVersion } from "./zonGraph";

const execFileAsync = promisify(execFile);

/**
 * CodeLens showing each `build.zig.zon` dependency's resolved version —
 * read from the dependency's own `build.zig.zon`, not fetched from the
 * web. Path-based dependencies resolve directly; url/hash-based ones
 * resolve through Zig's global package cache (`{cache}/p/{hash}`), which
 * is where `zig build`/`zig fetch` already leave them on disk once
 * fetched at least once — nothing is downloaded by this extension.
 */
export class ZonCodeLensProvider implements vscode.CodeLensProvider {
  private readonly _onDidChange = new vscode.EventEmitter<void>();
  readonly onDidChangeCodeLenses = this._onDidChange.event;

  /** Resolved once per extension session — the cache dir doesn't move. */
  private globalCacheDirPromise: Promise<string | undefined> | undefined;

  constructor(private readonly getZigPath: () => string) {}

  dispose(): void {
    this._onDidChange.dispose();
  }

  refresh(): void {
    this.globalCacheDirPromise = undefined;
    this._onDidChange.fire();
  }

  async provideCodeLenses(
    document: vscode.TextDocument,
  ): Promise<vscode.CodeLens[]> {
    if (document.uri.scheme !== "file") return [];
    if (path.basename(document.uri.fsPath) !== "build.zig.zon") return [];

    const deps = parseZonDependencies(document.getText());
    if (deps.length === 0) return [];

    const zonDir = path.dirname(document.uri.fsPath);
    const lenses: vscode.CodeLens[] = [];

    for (const dep of deps) {
      const range = document.lineAt(
        Math.min(dep.line, document.lineCount - 1),
      ).range;
      const version = await this.resolveVersion(zonDir, dep);
      lenses.push(
        new vscode.CodeLens(range, {
          title: version ? `v${version}` : "version unresolved",
          command: "",
        }),
      );
    }
    return lenses;
  }

  private async resolveVersion(
    zonDir: string,
    dep: { path?: string; hash?: string },
  ): Promise<string | undefined> {
    if (dep.path) {
      return readVersionAt(path.resolve(zonDir, dep.path));
    }
    if (dep.hash) {
      const cacheDir = await this.getGlobalCacheDir();
      if (!cacheDir) return undefined;
      return readVersionAt(path.join(cacheDir, "p", dep.hash));
    }
    return undefined;
  }

  private getGlobalCacheDir(): Promise<string | undefined> {
    this.globalCacheDirPromise ??= (async () => {
      try {
        const { stdout } = await execFileAsync(this.getZigPath(), ["env"]);
        return parseZigEnvField(stdout, "global_cache_dir");
      } catch {
        return undefined;
      }
    })();
    return this.globalCacheDirPromise;
  }
}

function readVersionAt(depDir: string): string | undefined {
  try {
    const source = fs.readFileSync(
      path.join(depDir, "build.zig.zon"),
      "utf8",
    );
    return parseZonVersion(source);
  } catch {
    return undefined;
  }
}
