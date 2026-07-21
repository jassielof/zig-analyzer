# Zig Analyzer for VS Code

VS Code client for [zig-analyzer](https://github.com/jassielof/zig-analyzer), a Zig language server built independently of the Zig compiler's internal APIs.

## Requirements

Released VSIX packages include the `zig-analyzer` server binary for the platform on which they were built, so no system-wide installation is required. Development builds still discover `zig-out/bin/zig-analyzer` (or `.exe` on Windows) automatically.

## Extension Settings

Settings live under the `zigAnalyzer` namespace. Client-only:

- `zigAnalyzer.serverPath`: Optional override path to the `zig-analyzer` executable or its containing directory. `${workspaceFolder}` (including `${workspaceFolder:name}` in multi-root workspaces) is supported. If empty, the extension uses its bundled server, then checks `${workspaceFolder}/zig-out/bin`, then looks for `zig-analyzer` on `PATH`.

For this repository, the optional setting is simply:

```json
{
  "zigAnalyzer.serverPath": "${workspaceFolder}/zig-out/bin"
}
```

### Packaging the bundled server

`pnpm run package` builds the server for the current host, stages it as `server/zig-analyzer[.exe]`, and includes it in the VSIX. Build and publish a package on each supported target platform; a native server binary cannot run on a different operating system or CPU architecture.
- `zigAnalyzer.trace.server`: Traces communication between VS Code and the language server (`off`, `messages`, `verbose`).

LSP-mirrored settings (also understood by the server via `workspace/configuration`) include formatter, inlay hints, build-on-save, zig/lib paths, snippets, semantic tokens, reference code lenses, and unused-declaration diagnostics. See the Settings UI under **Zig Analyzer**.

### Regenerating settings from the server schema

Configuration options are defined once in [`tools/config_gen/config.json`](tools/config_gen/config.json). After editing that file, run:

```sh
zig build gen
```

This regenerates `internal/zig_analyzer/Config.zig`, `schemas/zig-analyzer.schema.json`, `schemas/vscode-configuration.json`, and merges the VS Code properties into `package.json`.

### Formatting

By default, "Format Document" uses the built-in formatter (matching `zig fmt`). To run an external stdin/stdout formatter:

```json
{
    "zigAnalyzer.formatter.command": "/path/to/your/formatter",
    "zigAnalyzer.formatter.args": ["--some-flag"]
}
```

Set `"zigAnalyzer.formatter.enable": false` (or clear `formatter.command` to `""`) to disable server-side formatting.

**Contract your formatter must follow** — this is a hard requirement, not a suggestion, since the server pipes text through it directly with no validation of the output beyond "did it exit 0":

1. Read the entire document from **stdin**.
2. Write the fully formatted result to **stdout**.
3. Exit with code **0** on success.
4. On failure, write a message to **stderr** and exit non-zero — this is surfaced back to you as the formatting error, so make it useful.

Whatever you configure is spawned directly (never through a shell), so shell metacharacters in `args` are passed through literally, not interpreted — there's no injection risk from the arguments themselves. The command path itself is still a "run arbitrary program" setting, though, which is why it's excluded from what an untrusted workspace's committed settings can control — see [Security](#security) below.

### Security

`zigAnalyzer.serverPath`, `zigAnalyzer.zigPath`, and `zigAnalyzer.formatter.command` all name an executable this extension will run. To prevent a workspace you've opened (but not marked as trusted) from silently pointing one of these at something malicious via a committed `.vscode/settings.json`, all three are declared `"scope": "machine-overridable"` and listed under `capabilities.untrustedWorkspaces.restrictedConfigurations` — VS Code ignores workspace-level values for these specific settings until you trust the workspace. Set them in your user settings if you want them to apply everywhere regardless.

## Commands

- **Zig Analyzer: Restart Language Server** — stops and restarts the language server, picking up a changed `zigAnalyzer.serverPath` without reloading the window.
- **Zig Analyzer: Run Build Step** — lists the `build.zig` steps for the current project (via `zig build --list-steps`) and runs the one you pick as a VS Code task.

## Code lenses

When editing Zig files (with editor code lenses enabled):

- In `build.zig` (from the **language server**): a **zig build** lens above `fn build`, and a **zig build \<step\>** lens above each `b.step("…")`. Clicking runs the command `zigAnalyzer.executeBuild` — any LSP client can handle that command; the VS Code extension registers it as a task.
- Above `fn main` (VS Code extension helper): if `build.zig` wires that file as an executable root to a run step, the lens runs **zig build \<step\>**. Otherwise it falls back to **zig run** on that file.
- On top-level declarations (from the language server): a **N references** lens showing how many times the symbol is referenced within the build-graph compilation unit. Counts are for that binding only (e.g. `const types = lsp.types` does **not** count the `lsp.types` field access as a use of the alias).

## Known Issues

`zig-analyzer` is under active development. See the [project plan](https://github.com/jassielof/zig-analyzer) for what's implemented so far.
