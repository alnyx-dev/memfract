const std = @import("std");

const version = std.SemanticVersion{ .major = 1, .minor = 7, .patch = 0 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    if (target.result.os.tag != .windows) {
        @panic("Memfract uses the Windows API and can only be built for Windows");
    }

    const cli = addApp(b, target, optimize, "memfract", "src/cli.zig");
    cli.subsystem = .console;
    cli.root_module.linkSystemLibrary("shell32", .{});
    b.installArtifact(cli);

    const gui = addApp(b, target, optimize, "memfract-gui", "src/gui.zig");
    gui.subsystem = .windows;
    for ([_][]const u8{ "user32", "gdi32", "gdiplus", "dwmapi", "uxtheme", "advapi32" }) |lib| {
        gui.root_module.linkSystemLibrary(lib, .{});
    }
    b.installArtifact(gui);

    const demo = addApp(b, target, optimize, "target", "src/target.zig");
    demo.subsystem = .console;
    const demo_step = b.step("target", "Build the demo target process (target.exe)");
    demo_step.dependOn(&b.addInstallArtifact(demo, .{}).step);

    const repl = addApp(b, target, optimize, "memfract-repl", "src/main.zig");
    repl.subsystem = .console;
    const repl_step = b.step("repl", "Build the legacy interactive REPL");
    repl_step.dependOn(&b.addInstallArtifact(repl, .{}).step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const fixture = addApp(b, target, optimize, "fixture", "tests/fixture.zig");
    fixture.subsystem = .console;
    const smoke_cmd = b.addSystemCommand(&.{
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
    });
    smoke_cmd.addFileArg(b.path("tests/smoke.ps1"));
    smoke_cmd.addArtifactArg(cli);
    smoke_cmd.addArtifactArg(fixture);
    smoke_cmd.addFileArg(b.path("src/version.zig"));
    const smoke_step = b.step("smoke", "Run Windows integration smoke tests");
    smoke_step.dependOn(&smoke_cmd.step);

    const bench = b.addExecutable(.{
        .name = "memfract-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Benchmark scanning over synthetic memory (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    const run_step = b.step("run", "Run the JSON CLI");
    run_step.dependOn(&run_cli.step);

    const run_gui = b.addRunArtifact(gui);
    const run_gui_step = b.step("run-gui", "Run the GUI");
    run_gui_step.dependOn(&run_gui.step);
}

fn addApp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    name: []const u8,
    root: []const u8,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .version = version,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
        }),
    });
}
