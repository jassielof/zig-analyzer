# Zig Analyzer

We'll use Docent as reference project for testing (located in `dependencies/docent`), it's a multi-module project (similar to Cargo/Go workspaces), has dependencies, one which also has another dependency, etc.

## LSP

- [ ] Unlike Rust Analyzer, the Zig compiler can work without a build system script (Cargo.toml), as well as with one. Both cases need to be supported by detection of the presence of a build.zig file in the workspace root, if it exists, the build script should be used to detect dependencies, modules, etc. Otherwise, the workspace should be treated accordingly.
- [ ] Inlay hints work weirdly on structure functions, for example, in `build.zig` this `const toml_mod = b.dependency("toml", .{}).module("toml");` where `b.dependency()` is from `std.Build`, defined as `pub fn dependency(b: *Build, name: []const u8, args: anytype) *Dependency {}`, and it basically accepts 2 arguments, not 3, currently the inlay hints wrongly shows it as `b.dependency(b: "toml", name: .{})`, when it should be `b.dependency(name: "toml", args: .{})`, since `b` is the receiver of the function. This fix should happen overall, not just for the build script, is a general issue with paramater inlay hints of structure functions.
- [ ] The `@This()` built-in should be resolved for its container type, this mean if we have `src/root.zig` with its doc container doc comments, `@This()` on hover should render the doc comments of `src/root.zig`, if there's a `src/root.zig@Foo` structure, that within it has `@This()` on hover should render the doc comments of `src/root.zig@Foo`.
- [ ] Inlay hints aren't inferred for values, for example `const toml_mod = b.dependency("toml", .{}).module("toml");`, where `const toml_mod` should be inferred to be `const toml_mod: *Module`, where `*Module` is the return type of `b.dependency("toml", .{}).module("toml")`, which is `*std.Build.Module`, basically `pub fn module(d: *Dependency, name: []const u8) *Module {}`.
  - [ ] As well for constant strings, for example `const mod_name = "docent";` should be `const mod_name: *const [6:0]u8 = "docent";`, where `*const [6:0]u8` is the type of the string `"docent"`. And so on for all the other cases.

### Not planned for now

- [ ] Test gutter icons for test cases.

## VS Code Extension

- [x] Code lenses:
  - [x] For steps declarations, for example: `const run_step = b.step("cli", "Test the CLI");` should display a code lens to run the step `zig build cli`, with good UI/UX, and if possible the description of the step should be displayed in the code lens, for example: `Test the CLI`.
  - [x] For the entrypoint functions, such as `main()` or `build()`, for `build()` it's easy as it's just `zig build` on the workspace root where the build script lives. As for the `main()`, it's somewhat done I believe, and its dependent on whether the workspace has a build script or not, if it does, it should be smart to detect if the entrypoint file is the root module, which usually is, basically tracking, for example, the build script can define the executable module:

    ```zig
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = mod_name, .module = mod },
            .{ .name = "fangz", .module = fangz_mod },
            .{ .name = "carnaval", .module = carnaval_mod },
            .{ .name = "toml", .module = toml_mod },
            .{ .name = "typeset", .module = typeset_mod },
            .{ .name = "doc_comment", .module = doc_comment_mod },
            .{ .name = "fmt", .module = fmt_mod },
        },
    });

    const cli = b.addExecutable(.{
        .name = mod_name,
        // Add exectuable can take a version field, so that should be used for the metadata injection, IF IT'S AVAILABLE, in my case I simply won't use it, so it should fallback to the build.zig.zon version field instead. In the case where the user uses the version here from addExecutable, it's a SemanticVersion type.
        // .version =
        .root_module = cli_mod,
    });
    ```

    And the `src/cli/main.zig` file has a `main()` function.

    This would create a match, and it should display a code lens to run the main function, but it also needs to depend on the respective build step, which in this case is `cli`, defined as:

    ```zig
    const cli_step = b.step("cli", "Run the CLI");

    // ...

    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());

    cli_step.dependOn(&run_cli.step);

    if (b.args) |args| run_cli.addArgs(args);
    ```

    There one can track how to the executable `cli` is wired to the step `cli`, in any other case.
