// Client scaffolding only — no server lifecycle management. The server binary path is user-configured (`zigAnalyzer.serverPath`) with a PATH fallback to `zig-analyzer`.

import { execFile } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { promisify } from "node:util";
import * as vscode from "vscode";
import {
  LanguageClient,
  type LanguageClientOptions,
  type ServerOptions,
} from "vscode-languageclient/node";
import { ZigBuildCodeLensProvider } from "./buildCodeLenses";
import { ZonCodeLensProvider } from "./zonCodeLenses";

const execFileAsync = promisify(execFile);

let client: LanguageClient | undefined;
let codeLensProvider: ZigBuildCodeLensProvider | undefined;
let zonCodeLensProvider: ZonCodeLensProvider | undefined;
let bundledServerPath: string | undefined;

const docCommentEnterRules: vscode.OnEnterRule[] = [
  {
    beforeText: /^\s*\/\/\//,
    action: { indentAction: vscode.IndentAction.None, appendText: "/// " },
  },
  {
    beforeText: /^\s*\/\/!/,
    action: { indentAction: vscode.IndentAction.None, appendText: "//! " },
  },
];

export function activate(context: vscode.ExtensionContext): void {
  bundledServerPath = path.join(
    context.extensionPath,
    "server",
    serverExecutableName,
  );
  codeLensProvider = new ZigBuildCodeLensProvider();
  zonCodeLensProvider = new ZonCodeLensProvider(getZigPath);

  context.subscriptions.push(
    codeLensProvider,
    zonCodeLensProvider,
    // Register at activation as well as declaring it in language-configuration.json.
    // This keeps continuation working if another Zig extension also contributes the
    // `zig` language ID and its language configuration wins during startup.
    vscode.languages.setLanguageConfiguration("zig", {
      onEnterRules: docCommentEnterRules,
    }),
    vscode.languages.registerCodeLensProvider(
      [{ language: "zig", scheme: "file" }],
      codeLensProvider,
    ),
    vscode.languages.registerCodeLensProvider(
      [{ language: "zon", scheme: "file", pattern: "**/build.zig.zon" }],
      zonCodeLensProvider,
    ),
    vscode.workspace.onDidSaveTextDocument((doc) => {
      if (doc.uri.scheme !== "file") return;
      if (doc.uri.fsPath.endsWith("build.zig")) codeLensProvider?.refresh();
      if (path.basename(doc.uri.fsPath) === "build.zig.zon") {
        zonCodeLensProvider?.refresh();
      }
    }),
    vscode.commands.registerCommand("zigAnalyzer.restart", () => restart()),
    vscode.commands.registerCommand("zigAnalyzer.runBuildStep", () =>
      runBuildStepPicker(),
    ),
    vscode.commands.registerCommand(
      "zigAnalyzer.executeBuild",
      (stepName: string | null, folderUri: string | null) =>
        executeBuild(stepName, folderUri),
    ),
    vscode.commands.registerCommand(
      "zigAnalyzer.executeRunFile",
      (filePath: string) => executeRunFile(filePath),
    ),
    vscode.commands.registerCommand("zigAnalyzer.insertPlainLineAfter", () =>
      insertPlainLineAfter(),
    ),
    vscode.commands.registerCommand("zigAnalyzer.handleEnterKey", () =>
      handleEnterKey(),
    ),
    vscode.commands.registerCommand(
      "zigAnalyzer.showReferences",
      (uri: string, position: LspPosition, locations: LspLocation[]) =>
        showReferences(uri, position, locations),
    ),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("zigAnalyzer.zigPath")) {
        zonCodeLensProvider?.refresh(); // the cached global package cache dir came from the old zigPath
      }
      if (e.affectsConfiguration("zigAnalyzer.serverPath")) {
        void restart();
      }
    }),
  );

  void start();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}

async function start(): Promise<void> {
  const serverPath = getServerPath();

  const serverOptions: ServerOptions = {
    command: serverPath,
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "zig" },
      { scheme: "file", language: "zon" },
    ],
    synchronize: {
      configurationSection: "zigAnalyzer",
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.{zig,zon}"),
    },
    initializationOptions: getZigAnalyzerSettings(),
  };

  client = new LanguageClient(
    "zigAnalyzer",
    "Zig Analyzer",
    serverOptions,
    clientOptions,
  );

  try {
    await client.start();
  } catch (err) {
    void vscode.window.showErrorMessage(
      `Zig Analyzer: failed to start language server ("${serverPath}"). Set zigAnalyzer.serverPath or install zig-analyzer on PATH. ${String(err)}`,
    );
    client = undefined;
  }
}

async function restart(): Promise<void> {
  await client?.stop();
  client = undefined;
  await start();
}

/// Insert a line directly instead of invoking VS Code's Enter handling, which
/// intentionally bypasses `onEnterRules` such as doc-comment continuation.
async function insertPlainLineAfter(): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== "zig") return;

  const line = editor.document.lineAt(editor.selection.active.line);
  const indent = line.text.match(/^\s*/)?.[0] ?? "";
  const nextPosition = new vscode.Position(line.lineNumber + 1, indent.length);

  const applied = await editor.edit((edit) => {
    edit.insert(line.range.end, `\n${indent}`);
  });
  if (applied)
    editor.selection = new vscode.Selection(nextPosition, nextPosition);
}

const docCommentContinuePattern = /^(\s*)(\/\/\/|\/\/!)/;

/// Handles the plain Enter key for `.zig` files, manually continuing `///`/`//!` doc comments
/// instead of relying on `onEnterRules` (`language-configuration.json`). Doc comment content is
/// tagged `meta.embedded.block.markdown` (see the grammar's `embeddedLanguages` mapping, added so
/// doc comments render as Markdown) - which makes VS Code resolve the language *at the cursor* as
/// `markdown` there, same mechanism HTML uses for `<script>`/`<style>` blocks, so it uses
/// Markdown's Enter behavior instead of the onEnterRules registered for `zig`. This bypasses that
/// entirely for the one case we care about, falling back to the real default Enter handling (which
/// still works fine outside a doc comment) for everything else.
async function handleEnterKey(): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (
    editor &&
    editor.document.languageId === "zig" &&
    editor.selections.length === 1 &&
    editor.selection.isEmpty
  ) {
    const position = editor.selection.active;
    const textBeforeCursor = editor.document.lineAt(position.line).text
      .slice(0, position.character);
    const match = docCommentContinuePattern.exec(textBeforeCursor);

    if (match) {
      const [, indent, marker] = match;
      const applied = await editor.edit((edit) => {
        edit.insert(position, `\n${indent}${marker} `);
      });
      if (applied) return;
    }
  }

  await vscode.commands.executeCommand("default:type", { text: "\n" });
}

const serverExecutableName =
  process.platform === "win32" ? "zig-analyzer.exe" : "zig-analyzer";

/// Prefer a configured executable or directory. Expand workspace-folder variables
/// ourselves: VS Code does not expand variables read through `getConfiguration`.
/// With no setting, use the bundled server, a local build output, then fall back to PATH.
function getServerPath(): string {
  const configured = vscode.workspace
    .getConfiguration("zigAnalyzer")
    .get<string>("serverPath", "")
    .trim();

  if (configured)
    return executableInDirectory(expandWorkspaceFolder(configured));

  if (bundledServerPath && fs.existsSync(bundledServerPath)) {
    return bundledServerPath;
  }

  const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
  if (workspaceFolder) {
    const localBuild = path.join(
      workspaceFolder.uri.fsPath,
      "zig-out",
      "bin",
      serverExecutableName,
    );
    if (fs.existsSync(localBuild)) return localBuild;
  }

  return "zig-analyzer";
}

function executableInDirectory(candidate: string): string {
  try {
    return fs.statSync(candidate).isDirectory()
      ? path.join(candidate, serverExecutableName)
      : candidate;
  } catch {
    return candidate;
  }
}

function expandWorkspaceFolder(value: string): string {
  return value.replace(/\$\{workspaceFolder(?::([^}]+))?\}/g, (_, name) => {
    const folder = name
      ? vscode.workspace.workspaceFolders?.find((item) => item.name === name)
      : vscode.workspace.workspaceFolders?.[0];
    return folder?.uri.fsPath ?? _;
  });
}

function getZigPath(): string {
  const configured = vscode.workspace
    .getConfiguration("zigAnalyzer")
    .get<string>("zigPath", "zig");
  return configured || "zig";
}

/// Nested `zigAnalyzer` settings sent as `initializationOptions` and mirrored by
/// `workspace/configuration` (section `zigAnalyzer`).
function getZigAnalyzerSettings(): Record<string, unknown> {
  const c = vscode.workspace.getConfiguration("zigAnalyzer");
  return {
    enableSnippets: c.get("enableSnippets"),
    enableArgumentPlaceholders: c.get("enableArgumentPlaceholders"),
    completionLabelDetails: c.get("completionLabelDetails"),
    buildOnSave: {
      enable: c.get("buildOnSave.enable"),
      args: c.get("buildOnSave.args"),
    },
    semanticTokens: c.get("semanticTokens"),
    inlayHints: {
      enable: c.get("inlayHints.enable"),
      types: c.get("inlayHints.types"),
      structLiteralFieldType: c.get("inlayHints.structLiteralFieldType"),
      parameterNames: c.get("inlayHints.parameterNames"),
      builtins: c.get("inlayHints.builtins"),
      excludeSingleArgument: c.get("inlayHints.excludeSingleArgument"),
      hideRedundantParamNames: c.get("inlayHints.hideRedundantParamNames"),
      hideRedundantParamNamesLastToken: c.get(
        "inlayHints.hideRedundantParamNamesLastToken",
      ),
    },
    formatter: {
      enable: c.get("formatter.enable"),
      command: c.get("formatter.command"),
      args: c.get("formatter.args"),
    },
    referenceCodeLenses: c.get("referenceCodeLenses"),
    unusedDeclDiagnostics: c.get("unusedDeclDiagnostics"),
    namingConventionDiagnostics: c.get("namingConventionDiagnostics"),
    preferAstCheckAsChildProcess: c.get("preferAstCheckAsChildProcess"),
    builtinPath: c.get("builtinPath"),
    libPath: c.get("libPath"),
    zigPath: c.get("zigPath"),
    buildRunnerPath: c.get("buildRunnerPath"),
    globalCachePath: c.get("globalCachePath"),
  };
}

interface BuildStep {
  name: string;
  description: string;
  isDefault: boolean;
}

/// LSP-wire-shaped `Position`/`Location`, as sent in `zigAnalyzer.showReferences`'s command
/// arguments — plain JSON, not the `vscode.Position`/`vscode.Location` classes this command
/// converts them into before calling the `editor.action.showReferences` built-in.
interface LspPosition {
  line: number;
  character: number;
}

interface LspLocation {
  uri: string;
  range: { start: LspPosition; end: LspPosition };
}

function toVscodePosition(position: LspPosition): vscode.Position {
  return new vscode.Position(position.line, position.character);
}

/// Reference-count code lenses ("N references") call this to open the built-in Peek References
/// view, mirroring the clickable reference-count lens VS Code shows for TS/JS.
async function showReferences(
  uri: string,
  position: LspPosition,
  locations: LspLocation[],
): Promise<void> {
  const vscodeLocations = locations.map(
    (loc) =>
      new vscode.Location(
        vscode.Uri.parse(loc.uri),
        new vscode.Range(
          toVscodePosition(loc.range.start),
          toVscodePosition(loc.range.end),
        ),
      ),
  );
  await vscode.commands.executeCommand(
    "editor.action.showReferences",
    vscode.Uri.parse(uri),
    toVscodePosition(position),
    vscodeLocations,
  );
}

const DEFAULT_SUFFIX = " (default)";

/// Parses `zig build --list-steps` output. Each line is
/// `  <name>[ (default)]<gap>  <description>`, where the gap between name
/// and description is padded to a fixed column — so splitting on runs of
/// 2+ spaces (rather than relying on exact column widths, which shift
/// with the longest step name in a given project) is what's robust here.
function parseBuildSteps(output: string): BuildStep[] {
  return output
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => {
      const [rawName = "", ...rest] = line.split(/ {2,}/);
      const isDefault = rawName.endsWith(DEFAULT_SUFFIX);
      const name = isDefault
        ? rawName.slice(0, -DEFAULT_SUFFIX.length)
        : rawName;
      return { name, description: rest.join("  "), isDefault };
    });
}

/// Resolves which workspace folder to run `zig build` in: the only one if
/// there's just one, the active editor's folder if it belongs to one, and
/// a picker otherwise. Multi-root workspaces with several independent Zig
/// projects are the only case that needs the picker.
async function findZigProjectFolder(): Promise<
  vscode.WorkspaceFolder | undefined
> {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || folders.length === 0) {
    return undefined;
  }
  if (folders.length === 1) {
    return folders[0];
  }

  const activeUri = vscode.window.activeTextEditor?.document.uri;
  if (activeUri) {
    const owning = vscode.workspace.getWorkspaceFolder(activeUri);
    if (owning) {
      return owning;
    }
  }

  return vscode.window.showWorkspaceFolderPick({
    placeHolder: "Select the Zig project to build",
  });
}

function folderFromUriString(
  folderUri: string | null | undefined,
): vscode.WorkspaceFolder | undefined {
  if (!folderUri) return undefined;
  return vscode.workspace.getWorkspaceFolder(vscode.Uri.parse(folderUri));
}

async function executeBuild(
  stepName: string | null,
  folderUri: string | null,
): Promise<void> {
  const folder =
    folderFromUriString(folderUri) ?? (await findZigProjectFolder());
  if (!folder) {
    void vscode.window.showErrorMessage(
      "Zig Analyzer: no workspace folder open.",
    );
    return;
  }

  const zigPath = getZigPath();
  const args = stepName ? ["build", stepName] : ["build"];
  const title = stepName ? `zig build ${stepName}` : "zig build";

  const task = new vscode.Task(
    { type: "zig-analyzer-build", step: stepName ?? "" },
    folder,
    title,
    "zig-analyzer",
    new vscode.ProcessExecution(zigPath, args, { cwd: folder.uri.fsPath }),
    [],
  );
  task.presentationOptions = {
    reveal: vscode.TaskRevealKind.Always,
    panel: vscode.TaskPanelKind.Dedicated,
    clear: true,
  };
  await vscode.tasks.executeTask(task);
}

async function executeRunFile(filePath: string): Promise<void> {
  const uri = vscode.Uri.file(filePath);
  const folder =
    vscode.workspace.getWorkspaceFolder(uri) ?? (await findZigProjectFolder());
  if (!folder) {
    void vscode.window.showErrorMessage(
      "Zig Analyzer: no workspace folder open.",
    );
    return;
  }

  const zigPath = getZigPath();
  const task = new vscode.Task(
    { type: "zig-analyzer-run", file: filePath },
    folder,
    `zig run ${filePath}`,
    "zig-analyzer",
    new vscode.ProcessExecution(zigPath, ["run", filePath], {
      cwd: folder.uri.fsPath,
    }),
    [],
  );
  task.presentationOptions = {
    reveal: vscode.TaskRevealKind.Always,
    panel: vscode.TaskPanelKind.Dedicated,
    clear: true,
  };
  await vscode.tasks.executeTask(task);
}

async function runBuildStepPicker(): Promise<void> {
  const folder = await findZigProjectFolder();
  if (!folder) {
    void vscode.window.showErrorMessage(
      "Zig Analyzer: no workspace folder open.",
    );
    return;
  }

  const zigPath = getZigPath();
  let steps: BuildStep[];
  try {
    const { stdout } = await execFileAsync(zigPath, ["build", "--list-steps"], {
      cwd: folder.uri.fsPath,
    });
    steps = parseBuildSteps(stdout);
  } catch (err) {
    void vscode.window.showErrorMessage(
      `Zig Analyzer: failed to list build steps in "${folder.name}" (is "${zigPath}" on PATH, and does this folder have a build.zig?). ${String(err)}`,
    );
    return;
  }

  if (steps.length === 0) {
    void vscode.window.showInformationMessage(
      `Zig Analyzer: "${folder.name}" has no build steps.`,
    );
    return;
  }

  const picked = await vscode.window.showQuickPick(
    steps.map((step) => ({
      label: step.isDefault ? `$(star-full) ${step.name}` : step.name,
      description: step.description,
      step,
    })),
    { placeHolder: `Select a zig build step to run in "${folder.name}"` },
  );
  if (!picked) {
    return;
  }

  await executeBuild(picked.step.name, folder.uri.toString());
}
