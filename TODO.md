# Zig Analyzer

We'll use Docent as reference project for testing (located in `dependencies/docent`), it's a multi-module project (similar to Cargo/Go workspaces), has dependencies, one which also has another dependency, etc.

Granular implementation TODOs live as `// TODO:`/`// FIXME:` comments in the
files they apply to, not here — this file is just the open, tier-level
roadmap. Completed work isn't tracked here either; `git log` is the record
of what shipped and why.

## Already ahead of zls, worth protecting during any refactor

- Reference-count codeLens (`features/code_lens.zig`) — zls doesn't have this.
- Dimmed unused-declaration diagnostics via `DiagnosticTag.Unnecessary`.
- Doctest-as-hover-example (`test <ident> { ... }` shown as a hover example).
- `build.zig`-driven `main()`/step run tracking (best-effort, not hardcoded
  `zig build run` like zls).
- Configurable formatter and `zigPath`, not hardcoded to a bundled/downloaded
  Zig binary — the user controls both.

## Open work

### `@This()` hover

The `@This()` built-in currently falls back to showing the *enclosing
container's* doc comment. That's a stand-in, not the real answer: `@This()`
should show its own documentation, but that isn't in the stdlib — it'd need
fetching from the language reference (see below). Until that's wired up,
`const Foo = @This()` should at least render `Foo`'s own `///` doc comment
when the container has one, which it currently doesn't.

### Docent-based lints in the VS Code extension

Add an option to surface Docent's checks (naming conventions, formatting,
Zig Language Reference Style Guide adherence) as editor diagnostics —
either by shelling out to Docent or linking it as a library. Distinct from
Docent's other role here as a test fixture (a real multi-module workspace
for validating cross-file/package resolution).

## Deferred — needs more research/design before starting

- **Test gutter icons** for test cases.
- **Built-in function documentation.** Not in the stdlib — `@This()`,
  `@import()`, etc. have no doc comments to show on hover, because ZLS
  bundles `langref.html.in` (the template Zig itself uses to generate the
  language reference) precisely because there's no other source. Options,
  none fully satisfying: bundle the same template (extra maintenance,
  version-drift risk); link out to
  `https://ziglang.org/documentation/<version>/#<BuiltinName>` per builtin
  (simple, but doc comments become bare links, no inline content); or
  fetch+convert the online reference to Markdown at a pre-build step
  (adds a build-time dependency on network access).
