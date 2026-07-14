const std = @import("std");
const builtin = @import("builtin");

/// - compile release binaries for different targets
/// - compress them (.tar.xz, .tar.gz or .zip)
/// - optionally sign them with minisign (https://github.com/jedisct1/minisign)
/// - install artifacts and a `release.json` metadata file to `./zig-out`
pub fn release(
    b: *std.Build,
    release_artifacts: []const *std.Build.Step.Compile,
    released_version: std.SemanticVersion,
    minimum_build_zig_version: []const u8,
    minimum_runtime_zig_version: []const u8,
) void {
    std.debug.assert(release_artifacts.len > 0);

    const release_step = b.step("release", "Build all release artifacts. (requires tar and 7z)");
    const release_minisign = b.option(bool, "release-minisign", "Sign release artifacts with Minisign") orelse false;

    if (released_version.pre != null and released_version.build == null) {
        release_step.addError("Cannot build release because the version could not be resolved", .{}) catch @panic("OOM");
        return;
    }

    const FileExtension = enum {
        zip,
        @"tar.xz",
        @"tar.gz",
    };

    var compressed_artifacts: std.array_hash_map.String(std.Build.LazyPath) = .empty;

    for (release_artifacts) |exe| {
        const resolved_target = exe.root_module.resolved_target.?.result;
        const is_windows = resolved_target.os.tag == .windows;
        const exe_name = b.fmt("{s}{s}", .{ exe.name, resolved_target.exeFileExt() });

        const extensions: []const FileExtension = if (is_windows) &.{.zip} else &.{ .@"tar.xz", .@"tar.gz" };

        for (extensions) |extension| {
            const file_name = b.fmt("{s}-{t}-{t}-{f}.{t}", .{
                exe.name,
                resolved_target.cpu.arch,
                resolved_target.os.tag,
                released_version,
                extension,
            });

            const compress_cmd = std.Build.Step.Run.create(b, "compress artifact");
            compress_cmd.clearEnvironment();
            compress_cmd.step.max_rss = switch (extension) {
                .zip => 160 * 1024 * 1024, // 160 MiB
                .@"tar.xz" => 768 * 1024 * 1024, // 512 MiB
                .@"tar.gz" => 16 * 1024 * 1024, // 12 MiB
            };
            switch (extension) {
                .zip => {
                    compress_cmd.addArgs(&.{ "7z", "a", "-mx=9" });
                    compressed_artifacts.putNoClobber(b.allocator, file_name, compress_cmd.addOutputFileArg(file_name)) catch @panic("OOM");
                    compress_cmd.addArtifactArg(exe);
                    compress_cmd.addFileArg(exe.getEmittedPdb());
                    compress_cmd.addFileArg(b.path("LICENSE.txt"));
                    compress_cmd.addFileArg(b.path("README.adoc"));
                },
                .@"tar.xz",
                .@"tar.gz",
                => {
                    compress_cmd.setEnvironmentVariable("XZ_OPT", "-9");
                    compress_cmd.addArgs(&.{ "tar", "caf" });
                    compressed_artifacts.putNoClobber(b.allocator, file_name, compress_cmd.addOutputFileArg(file_name)) catch @panic("OOM");
                    compress_cmd.addPrefixedDirectoryArg("-C", exe.getEmittedBinDirectory());
                    compress_cmd.addArg(exe_name);

                    compress_cmd.addPrefixedDirectoryArg("-C", b.path("."));
                    compress_cmd.addArg("LICENSE.txt");
                    compress_cmd.addArg("README.adoc");

                    compress_cmd.addArgs(&.{
                        "--sort=name",
                        "--numeric-owner",
                        "--owner=0",
                        "--group=0",
                        "--mtime=1970-01-01",
                    });
                },
            }
        }
    }

    for (compressed_artifacts.keys(), compressed_artifacts.values()) |file_name, file_path| {
        const install_dir: std.Build.InstallDir = .{ .custom = "artifacts" };

        const install_tarball = b.addInstallFileWithDir(file_path, install_dir, file_name);
        release_step.dependOn(&install_tarball.step);

        if (release_minisign) {
            const minisign_basename = b.fmt("{s}.minisig", .{file_name});

            const minising_cmd = b.addSystemCommand(&.{ "minisign", "-Sm" });
            minising_cmd.clearEnvironment();
            minising_cmd.addFileArg(file_path);
            minising_cmd.addPrefixedFileArg("-s", .{ .cwd_relative = "minisign.key" });
            const minising_file_path = minising_cmd.addPrefixedOutputFileArg("-x", minisign_basename);

            const install_minising = b.addInstallFileWithDir(minising_file_path, install_dir, minisign_basename);
            release_step.dependOn(&install_minising.step);
        }
    }

    const source = b.fmt(
        \\{{
        \\  "version": "{[version]f}",
        \\  "zigVersion": "{[zig_version]f}",
        \\  "minimumBuildZigVersion": "{[minimum_build_zig_version]s}",
        \\  "minimumRuntimeZigVersion": "{[minimum_runtime_zig_version]s}",
        \\  "files": {[files]f}
        \\}}
        \\
    , .{
        .version = released_version,
        .zig_version = builtin.zig_version,
        .minimum_build_zig_version = minimum_build_zig_version,
        .minimum_runtime_zig_version = minimum_runtime_zig_version,
        .files = std.json.fmt(compressed_artifacts.keys(), .{}),
    });

    const write_files = b.addWriteFiles();
    const install_metadata = b.addInstallFile(write_files.add("release.json", source), "release.json");
    release_step.dependOn(&install_metadata.step);
}
