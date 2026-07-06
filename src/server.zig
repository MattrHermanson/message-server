const std = @import("std");
const net = @import("net");

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
            PortError.InvalidNumber => {
                try writer.print("Invalid Port Number\n", .{});
                try writer.flush();
            },
            PortError.WellKnownPort => {
                try writer.print("Invalid Port Number. Cannot use a well-known port\n", .{});
                try writer.flush();
            },
        }
        return 1;
    };

    const listener = try net.socket(
        net.SocketDomain.Ipv4,
        net.SocketType.Stream,
        0,
    );

    defer listener.deinit();

    // set socket options
    const reuse: i32 = 1;
    _ = try net.setsockopt(
        listener,
        net.SocketLevel.socket,
        net.SocketOption.reuse_address,
        @ptrCast(&reuse),
        @sizeOf(i32),
    );

    const address: net.Address = net.Address.initIp4WithString(port, "127.0.0.1") catch {
        // TODO: print error
        return 1;
    };

    try net.bind(listener, address);

    try net.listen(listener, 128);

    while (true) {
        var conn_address: net.Address = undefined;

        const socket = net.accept(listener, &conn_address) catch |err| {
            std.debug.print("error accept: {}\n", .{err});
            continue;
        };

        defer socket.deinit();

        // write to socket
    }

    return 0;
}

// Validate Port Number
const PortError = error{
    InvalidNumber,
    WellKnownPort,
};

fn validate_port(port_str: []const u8) PortError!u16 {

    // parse string to u16
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        return PortError.InvalidNumber;
    };

    // validate well-known ports
    if (port < 1024) {
        return PortError.WellKnownPort;
    }

    return port;
}
