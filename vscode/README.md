# Zig Analyzer

VS Code client for [zig-analyzer](https://github.com/jassielof/zig-analyzer), a Zig language server built independently of the Zig compiler's internal APIs.

## Requirements

This extension is a thin LSP client — it does not bundle or download the `zig-analyzer` server binary. Build it yourself from the [zig-analyzer repository](https://github.com/jassielof/zig-analyzer) and point this extension at the resulting executable.

## Extension Settings

* `zigAnalyzer.serverPath`: Path to the `zig-analyzer` executable. Required — the extension does not start a language server until this is set.
* `zigAnalyzer.trace.server`: Traces communication between VS Code and the language server (`off`, `messages`, `verbose`). Useful for debugging.

## Commands

* **Zig Analyzer: Restart Language Server** — stops and restarts the language server, picking up a changed `zigAnalyzer.serverPath` without reloading the window.

## Known Issues

`zig-analyzer` is under active development. See the [project plan](https://github.com/jassielof/zig-analyzer) for what's implemented so far.
