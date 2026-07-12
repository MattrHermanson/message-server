const std = @import("std");
const net = @import("net");
const kqueue = @import("../utils/kqueue.zig");

// TODO: goal -> be able to handle N clients with a kqueue
// problems to look out for
//  1. how will sockets get deinit'd
//  2. timeouts and closing connections

const BACKLOG_MAX = 128;
const KQUEUE_SIZE = 128;

pub const Server = struct {
    alloc: std.mem.Allocator,
    kq: kqueue.Kqueue,
    connected: u64,
    listener: net.Socket, // TODO: remove this

    pub fn init(allocator: std.mem.Allocator) !Server {
        return .{
            .alloc = allocator,
            .kq = kqueue.Kqueue.initWithSize(allocator, KQUEUE_SIZE),
        };
    }

    pub fn deinit(self: *Server) void {
        self.alloc.deinit();
        self.kq.deinit();
    }

    pub fn listen(self: *Server, address: net.Address) !void {
        // Could be moved into a run function

        const listener = try net.Socket.init( // TODO: only will work with Ipv4
            net.SocketDomain.Ipv4,
            net.SocketType.Stream,
            0,
        );

        self.listener = listener;

        // set socket options
        const reuse: i32 = 1;
        _ = try listener.setsockopt(
            net.SocketLevel.socket,
            net.SocketOption.reuse_address,
            @ptrCast(&reuse),
            @sizeOf(i32),
        );

        try listener.bind(address);

        try listener.listen(BACKLOG_MAX);

        const event = kqueue.Kevent{
            .identifier = @intCast(listener.socket),
            .filter = @intFromEnum(kqueue.Filter.Read),
            .flags = @intFromEnum(kqueue.Flag.Add),
            .fflags = 0,
            .data = 0,
            .udata = null,
            .ext = [_]u64{0} ** 4,
        };

        _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false);
    }

    pub fn run(self: Server) void {
        while (true) {
            const ready_list = try self.kq.kevent(null, true);

            // TODO: handle ready list based on what ext[2] or ext[3] tells you the
            // the connection is
            for (ready_list.new_events) |ev| {
                if (ev.identifier == self.listener.fd) {
                    var new_address: net.Address = undefined;

                    const new_connection = try self.listener.accept(&new_address);

                    const event = kqueue.Kevent{
                        .identifier = @intCast(new_connection.socket),
                        .filter = @intFromEnum(kqueue.Filter.Read),
                        .flags = @intFromEnum(kqueue.Flag.Add),
                        .fflags = 0,
                        .data = 0,
                        .udata = null,
                        .ext = [_]u64{0} ** 4,
                    };

                    _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false);

                    std.debug.print("connection accept'd\n", .{});
                } else {
                    std.debug.print("message recv'd\n", .{});
                }
            }
        }
    }
};
