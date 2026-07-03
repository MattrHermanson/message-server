const std = @import("std");

pub fn build(b: *std.Build) void {
    // 1. Standard options for target (OS/Architecture) and optimization (Debug/Release)
    const target = b.standardTargetOptions(.{});

    // ==========================================
    // Server Configuration
    // ==========================================
    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server.zig"),
            .target = target,
            .link_libc = true,
        }),
    });

    // Tell the build system to put the compiled binary in the `zig-out/bin` folder
    b.installArtifact(server_exe);

    // ==========================================
    // Client Configuration
    // ==========================================
    const client_exe = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .link_libc = true,
        }),
    });

    // Tell the build system to put the compiled binary in the `zig-out/bin` folder
    b.installArtifact(client_exe);

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
}
