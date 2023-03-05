const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .wasm32, .os_tag = .wasi },
    });

    const optimize = b.standardOptimizeOption(.{});

    const local_dependencies = b.option(bool, "local-dependencies", "build from local dependencies");

    const lunatic_zig = b.dependency("lunatic-zig", .{
        .target = target,
        //.optimize = optimize,
    });
    const bincode_zig = b.dependency("bincode-zig", .{
        .target = target,
        //.optimize = optimize,
    });

    const bincode_zig_local = b.createModule(.{
        .source_file = .{ .path = "../bincode-zig/bincode.zig" },
    });
    const lunatic_zig_local = b.createModule(.{
        .source_file = .{ .path = "../lunatic-zig/src/lunatic.zig" },
        .dependencies = &.{
            .{ .name = "bincode-zig", .module = bincode_zig_local },
        },
    });

    const exe = b.addExecutable(.{
        .name = "kahawatamu-lunatic",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    if (local_dependencies orelse false) {
        exe.addModule("lunatic-zig", lunatic_zig_local);
        exe.addModule("bincode-zig", bincode_zig_local);
    } else {
        exe.addModule("lunatic-zig", lunatic_zig.module("lunatic-zig"));
        exe.addModule("bincode-zig", bincode_zig.module("bincode-zig"));
    }
    exe.rdynamic = true;
    exe.install();

    const run_cmd = b.addSystemCommand(&.{ "lunatic", "run", exe.out_filename });
    run_cmd.cwd = std.fmt.allocPrint(b.allocator, "{s}/bin", .{b.install_path}) catch unreachable;
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the ap with lunatic");
    run_step.dependOn(&run_cmd.step);
}
