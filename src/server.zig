const std = @import("std");
const net = @import("utils/net.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();

    // stdout boilerplate
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    var writer = &file_writer.interface;

    // validate port number  TODO: move port validation and int cast to diff fn
    const port_str = args.next() orelse {
        try writer.print("Usage $server [port]\n", .{});
        try writer.flush();
        return 1;
    };

    // parse string to u16
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        try writer.print("Invalid Port Number\n", .{});
        try writer.flush();
        return 1;
    };

    // validate well-known ports
    if (port < 1024) {
        try writer.print("Invalid Port Number. Cannot use a well-known port\n", .{});
        try writer.flush();
        return 1;
    }

    // FIX: remove std.Io.net dependency
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", std.mem.nativeToBig(u16, port));

    const listener = try net.socket(
        net.SocketDomain.Ipv4,
        net.SocketType.Stream,
        0,
    );

    defer _ = std.c.close(listener);

    // set socket options
    const reuse: c_int = 1;
    try net.setsockopt(
        listener,
        net.SocketLevel.socket,
        net.SocketOption.reuse_address,
        @ptrCast(&reuse),
        @sizeOf(c_int),
    );

    // TODO: fill this with real values
    const address: net.Address = .{ .ip4 = .{
        .addr = 1234,
        .port = 1234,
    } };

    try net.bind(listener, address);
    // FIX: make sure to close listener on error

    try net.listen(listener, 128);
    // FIX: make sure to close listener on error

    while (true) {
        var conn_address: net.Address = undefined;

        const socket = net.accept(listener, &conn_address) catch |e| {
            std.debug.print("error accept: {}\n", .{e});
            continue;
        };

        defer _ = std.c.close(socket);

        // do something with connection
    }

    return 0;
}
