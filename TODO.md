# Zig Analyzer

- [x] Configurable formatter, currently it's hardcoded to always use `zig fmt --stdin`, always, regardless if the editor has a custom formatter configured, and it doesn't respect editor settings, if I want to bring my own `docent fmt --stdin` formatter I simply can't because both the VS Code extension and the LSP hardcode it to the Zig's standard one, plus it can't be disabled. When fixing this, it should respect the editor setting, and explicit ask for a standard input formatter, not via file path.
- [x] Reference counter, ZLS already can find references, so it should be easy to show reference counts as code lenses, this should be bounded to the build-graph compilation unit.
- [x] Robust refactoring for renaming declarations. I had a catastrophic experience with this, I tried to rename an allocator constant on a test file, and it renamed all of the project allocator constants, which shouldn't, it should have been bounded to the simple file as it wasn't even public, and it also renamed the allocator constant from my std. lib. breaking my whole installation and project.
- [x] Dimmed unused declarations diagnostics, this should consider public vs. non-public (private) declarations.
- [x] Doctests as documentation examples for declaration hover, these should be appended at the end as:
    ````
    ...
    ---
    ## Doctest example

    <doc comment from the doctest if available>

    ```zig
    <doctest content>
    ```
    ````
    Doc comments can technically be not in the same file, for public declarations, for example src/lib.zig@foo() is public and then someone would define the doctest in src/lib_test.zig@foo, but that's really an anti-pattern; doctests need to live along their definition within the same file.
- [ ] `main()` functions are hardcoded to be always run as `zig build run`, but that's not always the case, i could have many commands/main functions and each run with their own step name. It can fallback as best effort to `zig run <file>` for those that have no dependencies, but it should do a best-effort to analyze the build graph and fine the correct executables.
- [ ] ZLS will always try to download respective binary for the target found in the manifest (`build.zig.zon`) under `minimum_zig_version`, and this can't be disabled, we should allow the user to configure whether they want this to happen automatically or not.
- [ ] Lint or code quality checks are hardcoded and not configurable, this should be disabled and reworked fully. It should be disabled by default and toggable, but not configurable granularly, just whether they want lints or not (diagnostics as information level, or hint, whichever is better UX), the lints should strictly follow the Zig Language Reference Style Guide. This includes: spaces for indentation, indentation of 4 spaces, naming conventions (my docent dependency handles this already, so zig analyzer needs to reuse naming convention checks, etc.), trailing comman for lists with 3 or more elements (lists, function parameters, etc.), line length of 100 characters.
    - Partially addressed: removed the "Functions should be camelCase" quickfix/diagnostic — it matched a compiler message Zig no longer emits (verified empty on 0.16.0 `ast-check`), so it was dead code that could never have fired correctly. "var could be const" is kept as-is, always on: it's a genuine `zig build`-blocking compile error (not a self-computed lint), so it intentionally isn't gated behind the toggle below — hiding it by default would let the editor show a clean file that then fails to build.
    - Still open: there is no actual lint system to gate yet. A real "disabled by default, hint/info severity" toggle only makes sense once zig-analyzer computes its own style diagnostics (indentation, naming convention via docent's `identifier_case` rule, trailing comma, line length) instead of relying on the compiler's error bundle — that's the docent-consumption work called out above, still not started (docent's per-rule checks aren't exposed publicly yet; only doc-comment, naming-convention, and formatter checks are).
- [ ] **Test gutter icons** for test cases. By single projects, each project can be easily filtered and run individually with `zig test --filterflag "test ID"`, but if that test module depends on another module, this zig test breaks, so it's not possible to run that test individually for projects with dependencies. This needs to be marked as FIXME, for a robust workaround once it's possible, specially because for test modules, it's not possible to run a single test case, unless we add an option filter within the build filter, we could suggest the user (throw a warn, etc.)
- [x] Build steps from the script should be actionable, as in a code lens for each build step.
- [x] For each manifest dependency, if the dependency it's Zig-based or has as zig manfiest (build.zig.zon), the version should be displayed.
- [x] `@import()` doesn't seem to be able to suggest `.zon` files, nor to resolve its types, fix this.
- [x] `@import("root")` is buggy (https://codeberg.org/ziglang/vscode-zig/issues/510).
    - Hovering the `"root"` string itself showed nothing (hover.zig had no case for import-string-literal positions at all, unlike goto-definition) even though hovering an identifier bound to the same import worked fine — added `hoverDefinitionImportString`, reusing the exact doc-comment pipeline declaration-hover already uses.
    - `@import(...)` completion items (`std`, `builtin`, `root`, dependency names, named modules) never carried any documentation, only a bare path — added doc-comment lookups for that small fixed set (not for arbitrary filesystem directory listings, which stay cheap).
    - The "root only suggested if the file already imports something" claim didn't reproduce: built a minimal exe+lib repro and confirmed `root`/module-name completions self-heal (they're not gated on the file's own import content) once the build runner's background `zig build --build-runner` resolution finishes — it just has no way to tell the client to retry, so a fast first completion request after opening a file can permanently miss them from the client's perspective. Added a bounded (~2s, polled) wait so the first request rides out the common case instead of racing it, applied to both `@import(...)` and `.dependency()`/`.module()` completions plus import hover.
