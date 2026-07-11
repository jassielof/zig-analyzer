// Client scaffolding only — no server lifecycle management. The server
// binary path is user-configured (`zigAnalyzer.serverPath`) rather than
// auto-downloaded/managed; see project plan §5.

import * as vscode from "vscode";
import {
  LanguageClient,
  type LanguageClientOptions,
  type ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.commands.registerCommand("zigAnalyzer.restart", () => restart()),
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
