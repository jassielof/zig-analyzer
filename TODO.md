# Zig Analyzer

- [ ] Configurable formatter, currently it's hardcoded to always use `zig fmt --stdin`, always, regardless if the editor has a custom formatter configured, and it doesn't respect editor settings, if I want to bring my own `docent fmt --stdin` formatter I simply can't because both the VS Code extension and the LSP hardcode it to the Zig's standard one, plus it can't be disabled. When fixing this, it should respect the editor setting, and explicit ask for a standard input formatter, not via file path.
- [ ] Reference counter, ZLS already can find references, so it should be easy to show reference counts as code lenses, this should be bounded to the build-graph compilation unit.
- [ ] Robust refactoring for renaming declarations. I had a catastrophic experience with this, I tried to rename an allocator constant on a test file, and it renamed all of the project allocator constants, which shouldn't, it should have been bounded to the simple file as it wasn't even public, and it also renamed the allocator constant from my std. lib. breaking my whole installation and project.
- [ ] Dimmed unused declarations diagnostics, this should consider public vs. non-public (private) declarations.
- [ ] Doctests as documentation examples for declaration hover, these should be appended at the end as:
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
- [ ] Built-in functions documentation should be delegated to the online Zig documentation, currently we depend on the langref.html.in which is huge, we need to fetch it on every update, etc. To make things easier, we should just use a simple template to link to it, for example, for `@This()` the hover/doc for it would be `See [`@This()`](https://ziglang.org/documentation/0.16.0/#This) in the _Language Reference_.`, for `@import()` it would be `See [`@import()`](https://ziglang.org/documentation/0.16.0/#import) in the _Language Reference_.`, and so for all built-in functions. Once this is done, we can rmeove and drop the langref.html.in relevant parsing code for builtin docs.
- [ ] **Test gutter icons** for test cases. By single projects, each project can be easily filtered and run individually with `zig test --filterflag "test ID"`, but if that test module depends on another module, this zig test breaks, so it's not possible to run that test individually for projects with dependencies. This needs to be marked as FIXME, for a robust workaround once it's possible, specially because for test modules, it's not possible to run a single test case, unless we add an option filter within the build filter, we could suggest the user (throw a warn, etc.)
- [ ] Build steps from the script should be actionable, as in a code lens for each build step.
- [ ] For each manifest dependency, if the dependency it's Zig-based or has as zig manfiest (build.zig.zon), the version should be displayed.
- [ ] Remove Tracy usage, traicing and profiling will be done once the LSP is robust, correct, and stable, in the meantime, no pre-mature optimization will be done.

