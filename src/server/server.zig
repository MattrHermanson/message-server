const std = @import("std");
const net = @import("net");
const kqueue = @import("kqueue");

// TODO: goal -> be able to handle N clients with a kqueue
// problems to look out for
//  1. how will sockets get deinit'd
//  2. timeouts and closing connections

const BACKLOG_MAX = 128;
const KQUEUE_SIZE = 128;

pub const Connection = union(enum) {
    listener: net.Socket,
    client: Client,
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    kq: kqueue.Kqueue,
    connected: u64,
    listener: net.Socket, // TODO: remove this later

    pub fn init(allocator: std.mem.Allocator) !Server {
        return .{
            .alloc = allocator,
            .kq = try kqueue.Kqueue.initWithSize(allocator, KQUEUE_SIZE),
            .connected = 0,
            .listener = undefined,
        };
    }

    pub fn deinit(self: *Server) void {
        self.alloc.deinit();
        self.kq.deinit();
    }

    pub fn listen(self: *Server, address: net.Address) !void {
        // Could be moved into a run function

        var listener = try net.Socket.init( // TODO: only will work with Ipv4
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

        var conn: Connection = .{ .listener = listener };

        const event = kqueue.Kevent{
            .identifier = @intCast(listener.fd),
            .filter = @intFromEnum(kqueue.Filter.Read),
            .flags = @intFromEnum(kqueue.Flag.Add),
            .fflags = 0,
            .data = 0,
            .udata = @ptrCast(&conn),
            .ext = [_]u64{0} ** 4,
        };

        _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false, null);
    }

    // TODO: get rid of error return
    pub fn run(self: *Server) !void {
        std.debug.print("Server Running...\n", .{});

        while (true) {
            const ready_list = try self.kq.kevent(&.{}, true, null);

            for (ready_list) |ev| {
                if (ev.udata) |raw_ptr| {
                    const conn: *Connection = @ptrCast(@alignCast(raw_ptr));

                    switch (conn.*) {
                        .listener => {
                            // listener is ready

                            // accept connection and pack connection union into udata
                            const new_socket = try self.listener.accept();
                            var new_conn: Connection = .{ .client = try Client.init(self.alloc, new_socket) };

                            const event = kqueue.Kevent{
                                .identifier = new_conn.client.socket.fd,
                                .filter = @intFromEnum(kqueue.Filter.Read),
                                .flags = @intFromEnum(kqueue.Flag.Add),
                                .fflags = 0,
                                .data = 0,
                                .udata = @ptrCast(&new_conn),
                                .ext = [_]u64{0} ** 4,
                            };

                            // register event with kq
                            _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false, null);
                        },
                        .client => {
                            // client is ready

                            // Read
                            if (kqueue.checkFilter(ev, kqueue.Filter.Read)) {
                                // do read
                            }

                            // Write
                            if (kqueue.checkFilter(ev, kqueue.Filter.Write)) {
                                // do write
                            }

                            // Close connection
                            if (kqueue.checkFlag(ev, kqueue.Flag.EOF)) {
                                conn.client.deinit();
                                std.debug.print("connection closed\n", .{});
                            }
                        },
                    }
                } else {
                    // no udata pointer
                    // but should have one??
                    unreachable;
                }
            }
        }
    }
};

pub const Client = struct {
    socket: net.Socket,

    alloc: std.mem.Allocator,

    read_buf: []u8, // Could switch to Reader struct later
    write_buf: []u8,

    // could put timeout linked list nodes here

    pub fn init(allocator: std.mem.Allocator, socket: net.Socket) !Client {
        const read_buf = try allocator.alloc(u8, 4096);
        const write_buf = try allocator.alloc(u8, 4096);

        return .{
            .socket = socket,
            .alloc = allocator,
            .read_buf = read_buf,
            .write_buf = write_buf,
        };
    }

    pub fn deinit(self: Client) void {
        self.socket.deinit();
        self.alloc.free(self.read_buf);
        self.alloc.free(self.write_buf);
    }
};
