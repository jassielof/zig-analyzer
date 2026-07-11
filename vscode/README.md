# Zig Analyzer

VS Code client for [zig-analyzer](https://github.com/jassielof/zig-analyzer), a Zig language server built independently of the Zig compiler's internal APIs.

## Requirements

This extension is a thin LSP client — it does not bundle or download the `zig-analyzer` server binary. Build it yourself from the [zig-analyzer repository](https://github.com/jassielof/zig-analyzer) and point this extension at the resulting executable.

## Extension Settings

* `zigAnalyzer.serverPath`: Path to the `zig-analyzer` executable. Required — the extension does not start a language server until this is set.
* `zigAnalyzer.zigPath`: Path to the `zig` executable, used by **Zig Analyzer: Run Build Step** (default `zig`, i.e. whatever's on `PATH`).
* `zigAnalyzer.trace.server`: Traces communication between VS Code and the language server (`off`, `messages`, `verbose`). Useful for debugging.
* `zigAnalyzer.formatter.command` / `zigAnalyzer.formatter.args`: Override the formatter used by "Format Document" (see [Formatting](#formatting) below).

### Formatting

By default, "Format Document" runs the standard, zero-config `zig fmt --stdin`. If you'd rather use a different `zig` toolchain, or a wrapper script that also runs a linter, set:

```json
{
  "zigAnalyzer.formatter.command": "/path/to/your/formatter",
  "zigAnalyzer.formatter.args": ["--some-flag"]
}
```

**Contract your formatter must follow** — this is a hard requirement, not a suggestion, since the server pipes text through it directly with no validation of the output beyond "did it exit 0 with nothing on stderr":

1. Read the entire document from **stdin**.
2. Write the fully formatted result to **stdout**.
3. Exit with code **0** on success.
4. On failure, write a message to **stderr** and exit non-zero — this is surfaced back to you as the formatting error, so make it useful.

Whatever you configure is spawned directly (never through a shell), so shell metacharacters in `args` are passed through literally, not interpreted — there's no injection risk from the arguments themselves. The command path itself is still a "run arbitrary program" setting, though, which is why it's excluded from what an untrusted workspace's committed settings can control — see [Security](#security) below.

### Security

`zigAnalyzer.serverPath`, `zigAnalyzer.zigPath`, and `zigAnalyzer.formatter.command` all name an executable this extension will run. To prevent a workspace you've opened (but not marked as trusted) from silently pointing one of these at something malicious via a committed `.vscode/settings.json`, all three are declared `"scope": "machine-overridable"` and listed under `capabilities.untrustedWorkspaces.restrictedConfigurations` — VS Code ignores workspace-level values for these specific settings until you trust the workspace. Set them in your user settings if you want them to apply everywhere regardless.

## Commands

* **Zig Analyzer: Restart Language Server** — stops and restarts the language server, picking up a changed `zigAnalyzer.serverPath` without reloading the window.
* **Zig Analyzer: Run Build Step** — lists the `build.zig` steps for the current project (via `zig build --list-steps`) and runs the one you pick as a VS Code task.

## Known Issues

`zig-analyzer` is under active development. See the [project plan](https://github.com/jassielof/zig-analyzer) for what's implemented so far.
