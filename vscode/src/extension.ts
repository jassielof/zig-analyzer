// Client scaffolding only — no server lifecycle management. The server binary path is user-configured (`zigAnalyzer.serverPath`) rather than auto-downloaded/managed; see project plan §5.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as vscode from "vscode";
import {
  LanguageClient,
  type LanguageClientOptions,
  type ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

const execFileAsync = promisify(execFile);

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.commands.registerCommand("zigAnalyzer.restart", () => restart()),
    vscode.commands.registerCommand("zigAnalyzer.runBuildStep", () =>
      runBuildStep(),
    ),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("zigAnalyzer.formatter")) {
        void client?.sendNotification("workspace/didChangeConfiguration", {
          settings: { formatter: getFormatterConfig() },
        });
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
  if (!serverPath) {
    return;
  }

  const serverOptions: ServerOptions = {
    command: serverPath,
    transport: TransportKind.stdio,
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "zig" }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.zig"),
    },
    initializationOptions: {
      formatter: getFormatterConfig(),
    },
  };

  client = new LanguageClient(
    "zigAnalyzer",
    "Zig Analyzer",
    serverOptions,
    clientOptions,
  );

  await client.start();
}

async function restart(): Promise<void> {
  await client?.stop();
  client = undefined;
  await start();
}

function getServerPath(): string | undefined {
  const configured = vscode.workspace
    .getConfiguration("zigAnalyzer")
    .get<string>("serverPath", "");

  if (!configured) {
    void vscode.window.showWarningMessage(
      'Zig Analyzer: set "zigAnalyzer.serverPath" to the zig-analyzer executable to enable language features.',
    );
    return undefined;
  }
  return configured;
}

interface FormatterConfig {
  command: string;
  args: string[];
}

/// Sent to the server as both `initialize`'s `initializationOptions` and
/// `workspace/didChangeConfiguration`'s `settings` (see
/// `Server.applyOptions` in src/lib/server.zig — both parse the same
/// `{ formatter: { command, args } }` shape). The configured command must
/// behave like `zig fmt --stdin`: read the whole document from stdin,
/// write the fully formatted result to stdout, exit 0 on success.
function getFormatterConfig(): FormatterConfig {
  const config = vscode.workspace.getConfiguration("zigAnalyzer");
  return {
    command: config.get<string>("formatter.command", "zig") || "zig",
    args: config.get<string[]>("formatter.args", ["fmt", "--stdin"]),
  };
}

function getZigPath(): string {
  const configured = vscode.workspace
    .getConfiguration("zigAnalyzer")
    .get<string>("zigPath", "zig");
  return configured || "zig";
}

interface BuildStep {
  name: string;
  description: string;
  isDefault: boolean;
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

async function runBuildStep(): Promise<void> {
  const folder = await findZigProjectFolder();
  if (!folder) {
    void vscode.window.showErrorMessage("Zig Analyzer: no workspace folder open.");
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

  const task = new vscode.Task(
    { type: "zig-analyzer-build", step: picked.step.name },
    folder,
    `zig build ${picked.step.name}`,
    "zig-analyzer",
    new vscode.ProcessExecution(zigPath, ["build", picked.step.name], {
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
