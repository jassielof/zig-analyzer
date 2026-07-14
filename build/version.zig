const std = @import("std");

/// Returns `MAJOR.MINOR.PATCH-dev` when `git describe` failed.
pub fn getVersion(b: *std.Build, package_version: std.SemanticVersion) std.SemanticVersion {
    const version_string = b.option([]const u8, "version-string", "Override the version of this build. Must be a semantic version.");
    if (version_string) |semver_string| {
        return std.SemanticVersion.parse(semver_string) catch |err| {
            std.debug.panic("Expected -Dversion-string={s} to be a semantic version: {}", .{ semver_string, err });
        };
    }

    if (package_version.pre == null) return package_version;

    const argv: []const []const u8 = &.{
        "git", "-C", b.pathFromRoot("."), "--git-dir", ".git", "describe", "--match", "*.*.*", "--tags",
    };
    var code: u8 = undefined;
    const git_describe_untrimmed = b.runAllowFail(argv, &code, .ignore) catch |err| {
        const argv_joined = std.mem.join(b.allocator, " ", argv) catch @panic("OOM");
        std.log.warn(
            \\Failed to run git describe to resolve the version: {}
            \\command: {s}
            \\
            \\Consider passing the -Dversion-string flag to specify the version.
        , .{ err, argv_joined });
        return package_version;
    };

    const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

    switch (std.mem.count(u8, git_describe, "-")) {
        0 => {
            // Tagged release version (e.g. 0.10.0).
            return package_version;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.216+34ce200).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;
            _ = tagged_ancestor;

            return .{
                .major = package_version.major,
                .minor = package_version.minor,
                .patch = package_version.patch,
                .pre = b.fmt("dev.{s}", .{commit_height}),
                .build = if (std.mem.startsWith(u8, commit_id, "g")) commit_id[1..] else commit_id,
            };
        },
        else => {
            std.debug.print("Unexpected 'git describe' output: '{s}'\n", .{git_describe});
            return package_version;
        },
    }
}
