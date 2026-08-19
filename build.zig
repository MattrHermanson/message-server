const std = @import("std");

pub fn build(b: *std.Build) void {
    // 1. Standard options for target (OS/Architecture) and optimization (Debug/Release)
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kqueue_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/kqueue/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const kqueue_module = b.createModule(.{
        .root_source_file = b.path("src/kqueue/kqueue.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    kqueue_module.addImport("libc", kqueue_translate_c.createModule());

    const net_translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/net/c.h"),
        .target = target,
        .optimize = optimize,
    });

    const net_module = b.createModule(.{
        .root_source_file = b.path("src/net/net.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Extracted from inline array to avoid pointer issues
    net_module.addImport("libc", net_translate_c.createModule());

    const server_module = b.createModule(.{
        .root_source_file = b.path("src/server/server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    server_module.addImport("net", net_module);
    server_module.addImport("kqueue", kqueue_module);

    // ==========================================
    // Server Configuration
    // ==========================================
    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = false,
            .link_libc = true,
        }),
    });

    server_exe.root_module.addImport("net", net_module);
    server_exe.root_module.addImport("kqueue", kqueue_module);

    // Tell the build system to put the compiled binary in the `zig-out/bin` folder
    b.installArtifact(server_exe);

    // ==========================================
    // Client Configuration
    // ==========================================
    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .link_libc = true,
        }),
    });

    client_exe.root_module.addImport("net", net_module);

    // Tell the build system to put the compiled binary in the `zig-out/bin` folder
    b.installArtifact(client_exe);

    // ==========================================
    // Testing Configuration
    // ==========================================
    const test_exe = b.addTest(.{
        .name = "Tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests/tests.zig"),
            .target = b.graph.host,
        }),
    });

    test_exe.root_module.addImport("net", net_module);
    test_exe.root_module.addImport("kqueue", kqueue_module);
    test_exe.root_module.addImport("server", server_module);

    b.installArtifact(test_exe);

    // ==========================================
    // Optional: Setup "Run" Commands
    // ==========================================
    // This allows you to run `zig build run-server` or `zig build run-client`

    // Server run step
    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }
    const run_server_step = b.step("run-server", "Run the server application");
    run_server_step.dependOn(&run_server_cmd.step);

    // Client run step
    const run_client_cmd = b.addRunArtifact(client_exe);
    run_client_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_client_cmd.addArgs(args);
    }
    const run_client_step = b.step("run-client", "Run the client application");
    run_client_step.dependOn(&run_client_cmd.step);

    // Server Testing step
    const test_cmd = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_cmd.step);
}
