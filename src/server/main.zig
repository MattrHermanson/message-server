const std = @import("std");
const net = @import("net");
const server = @import("server.zig");
const Threadpool = @import("threadpool").Threadpool;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();

    // stdout boilerplate
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    var writer = &file_writer.interface;

    // validate port number
    const port_str = args.next() orelse {
        try writer.print("Usage $server [port]\n", .{});
        try writer.flush();
        return 1;
    };

    const port = validate_port(port_str) catch |err| {
        switch (err) {
            error.InvalidNumber => {
                try writer.print("Invalid Port Number\n", .{});
                try writer.flush();
            },
            error.WellKnownPort => {
                try writer.print("Invalid Port Number. Cannot use a well-known port\n", .{});
                try writer.flush();
            },
        }
        return 1;
    };

    const address: net.Address = net.Address.initIp4WithString(port, "127.0.0.1") catch {
        // TODO: print error
        return 1;
    };

    // FIX: remove this -- here for ref'ing test suite in Threadpool
    var thrd_pool = try Threadpool.create(
        io,
        std.heap.c_allocator,
        try std.Thread.getCpuCount(),
    );
    thrd_pool.destroy();

    // TODO: create setup, handle, and onComplete functions
    var sv = try server.Server.init(
        io,
        std.heap.c_allocator,
        null,
        handle,
        null,
        .fromSeconds(60),
    );

    try sv.listen(address);

    sv.run() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };

    return 0;
}

// Validate Port Number
fn validate_port(port_str: []const u8) !u16 {

    // parse string to u16
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        return error.InvalidNumber;
    };

    // validate well-known ports
    if (port < 1024) {
        return error.WellKnownPort;
    }

    return port;
}

// TODO: test this server abstractions
// implement thread pool

//fn setup(client: *server.Client) void {}

fn handle(client: *server.Client, msg: []u8) server.HandlerFnError!bool {
    defer client.allocator.free(msg);

    client.write(msg) catch |err| {
        std.debug.print("error: {}", .{err});
        return true;
    };

    std.debug.print("msg {s}\n", .{msg});
    return false;
}

//fn onComplete(client: *server.Client) server.HandlerFnError!bool {}
