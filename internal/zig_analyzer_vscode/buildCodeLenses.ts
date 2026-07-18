import * as fs from "node:fs";
import * as path from "node:path";
import * as vscode from "vscode";
import {
  findMainFnLines,
  parseBuildScript,
  runStepForFile,
  type BuildScriptInfo,
} from "./buildGraph";

/**
 * Code lenses for Zig run targets (client-side):
 * - Above `fn main`: prefer `zig build <step>` when build.zig wires this
 *   file as an executable root to a named run step; otherwise
 *   `zig run <file>`.
 *
 * Build-step lenses inside `build.zig` (`b.step("…")`, `fn build`) come from
 * the language server (`textDocument/codeLens`) so any LSP client can show them.
 */
export class ZigBuildCodeLensProvider implements vscode.CodeLensProvider {
  private readonly _onDidChange = new vscode.EventEmitter<void>();
  readonly onDidChangeCodeLenses = this._onDidChange.event;

  /** Per-workspace-folder cache of parsed build.zig. */
  private readonly cache = new Map<
    string,
    { mtimeMs: number; info: BuildScriptInfo }
  >();

  dispose(): void {
    this._onDidChange.dispose();
    this.cache.clear();
  }

  refresh(): void {
    this.cache.clear();
    this._onDidChange.fire();
  }

  provideCodeLenses(
    document: vscode.TextDocument,
  ): vscode.ProviderResult<vscode.CodeLens[]> {
    if (document.uri.scheme !== "file") return [];

    // `build.zig` step lenses are provided by the language server.
    if (path.basename(document.uri.fsPath) === "build.zig") return [];

    const folder = vscode.workspace.getWorkspaceFolder(document.uri);
    const lenses: vscode.CodeLens[] = [];

    const mainLines = findMainFnLines(document.getText());
    if (mainLines.length === 0) return [];

    const step =
      folder !== undefined
        ? runStepForFile(
            folder.uri.fsPath,
            this.buildInfoFor(folder),
            document.uri.fsPath,
          )
        : null;

    for (const line of mainLines) {
      if (step && folder) {
        lenses.push(
          lensAt(document, line, `zig build ${step}`, "zigAnalyzer.executeBuild", [
            step,
            folder.uri.toString(),
          ]),
        );
      } else {
        lenses.push(
          lensAt(document, line, "zig run", "zigAnalyzer.executeRunFile", [
            document.uri.fsPath,
          ]),
        );
      }
    }
    return lenses;
  }

  private buildInfoFor(folder: vscode.WorkspaceFolder): BuildScriptInfo {
    const buildPath = path.join(folder.uri.fsPath, "build.zig");
    let mtimeMs = -1;
    try {
      mtimeMs = fs.statSync(buildPath).mtimeMs;
    } catch {
      return {
        buildFnLine: null,
        steps: [],
        executableRootToRunStep: new Map(),
      };
    }

    const cached = this.cache.get(folder.uri.fsPath);
    if (cached && cached.mtimeMs === mtimeMs) return cached.info;

    let source: string;
    try {
      source = fs.readFileSync(buildPath, "utf8");
    } catch {
      return {
        buildFnLine: null,
        steps: [],
        executableRootToRunStep: new Map(),
      };
    }

    const info = parseBuildScript(source);
    this.cache.set(folder.uri.fsPath, { mtimeMs, info });
    return info;
  }
}

function lensAt(
  document: vscode.TextDocument,
  line: number,
  title: string,
  command: string,
  args: unknown[],
): vscode.CodeLens {
  const range = document.lineAt(Math.min(line, document.lineCount - 1)).range;
  return new vscode.CodeLens(range, {
    title: `▶ ${title}`,
    command,
    arguments: args,
  });
}
