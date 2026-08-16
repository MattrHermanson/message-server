const std = @import("std");
const net = @import("net");
const server = @import("server.zig");

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

    const address: net.Address = net.Address.initIp4WithString(port, "127.0.0.1") catch {
        // TODO: print error
        return 1;
    };

    // TODO: this is where server stuff will go
    var sv = try server.Server.init(std.heap.c_allocator);

    try sv.listen(address);

    sv.run() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };

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
