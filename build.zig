const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .wasm32, .os_tag = .wasi },
    });

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const lunatic_zig = b.dependency("lunatic-zig", .{
        .target = target,
    });
    const s2s = b.dependency("s2s", .{
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "kahawatamu-lunatic",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("lunatic-zig", lunatic_zig.module("lunatic-zig"));
    exe.addModule("s2s", s2s.module("s2s"));
    exe.export_symbol_names = &.{
        "handle",
    };
    exe.install();

    const run_cmd = b.addSystemCommand(&.{ "lunatic", "run", exe.out_filename });
    run_cmd.cwd = std.fmt.allocPrint(b.allocator, "{s}/bin", .{b.install_path}) catch unreachable;
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the ap with lunatic");
    run_step.dependOn(&run_cmd.step);
}
