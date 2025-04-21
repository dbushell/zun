const std = @import("std");

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
};

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});

    for (targets) |t| {
        const triple = try t.zigTriple(b.allocator);
        const target = b.resolveTargetQuery(t);

        const exe_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = "zun",
            .root_module = exe_mod,
        });

        const out = b.addInstallArtifact(exe, .{
            .dest_dir = .{
                .override = .{ .custom = triple },
            },
        });
        b.getInstallStep().dependOn(&out.step);

        b.installArtifact(exe);

        if (optimize == .Debug and t.os_tag == .macos) {
            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }
            const run_step = b.step("run", "Run the app");
            run_step.dependOn(&run_cmd.step);
            run_step.dependOn(&out.step);
            const exe_unit_tests = b.addTest(.{
                .root_module = exe_mod,
            });
            const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
            const test_step = b.step("test", "Run unit tests");
            test_step.dependOn(&run_exe_unit_tests.step);
        }
    }
}
