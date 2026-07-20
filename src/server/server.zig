const std = @import("std");
const net = @import("net");
const kqueue = @import("kqueue");

// TODO: current goal -> be able to handle N clients with a kqueue
// problems to look out for
//  1. how will sockets get deinit'd
//  2. timeouts and closing connections

const BACKLOG_MAX = 128;
const KQUEUE_SIZE = 128;

pub const Connection = union(enum) {
    listener: *net.Socket,
    client: *Client,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    kq: kqueue.Kqueue,
    connected: u64,

    pub fn init(allocator: std.mem.Allocator) !Server {
        return .{
            .allocator = allocator,
            .kq = try kqueue.Kqueue.initWithSize(allocator, KQUEUE_SIZE),
            .connected = 0,
        };
    }

    pub fn deinit(self: *Server) void {
        self.alloc.deinit();
        self.kq.deinit();
    }

    pub fn listen(self: *Server, address: net.Address) !void {
        var listener_ptr = try self.allocator.create(net.Socket);

        listener_ptr.* = try net.Socket.init( // TODO: only will work with Ipv4
            net.SocketDomain.Ipv4,
            net.SocketType.Stream,
            0,
            true,
        );

        // set socket options
        const reuse: i32 = 1;
        _ = try listener_ptr.setsockopt(
            net.SocketLevel.socket,
            net.SocketOption.reuse_address,
            @ptrCast(&reuse),
            @sizeOf(i32),
        );

        try listener_ptr.bind(address);

        try listener_ptr.listen(BACKLOG_MAX);

        // put listener connection on the heap
        const conn = try self.allocator.create(Connection);
        conn.* = .{ .listener = listener_ptr };

        const event = kqueue.Kevent{
            .identifier = @intCast(listener_ptr.fd),
            .filter = @intFromEnum(kqueue.Filter.Read),
            .flags = @intFromEnum(kqueue.Flag.Add),
            .fflags = 0,
            .data = 0,
            .udata = @ptrCast(conn),
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

                            // TODO: use object pool to allocate connections

                            // accept connection and pack connection union into udata
                            const new_socket = try conn.listener.*.accept();
                            const new_conn = try self.allocator.create(Connection);
                            const new_client = try Client.create(self.allocator, new_socket);
                            new_conn.* = .{ .client = new_client };

                            const event = kqueue.Kevent{
                                .identifier = new_conn.client.socket.fd,
                                .filter = @intFromEnum(kqueue.Filter.Read),
                                .flags = @intFromEnum(kqueue.Flag.Add),
                                .fflags = 0,
                                .data = 0,
                                .udata = @ptrCast(new_conn),
                                .ext = [_]u64{0} ** 4,
                            };

                            // register event with kq
                            _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false, null);
                        },
                        .client => {
                            // client is ready

                            // Read
                            if (kqueue.checkFilter(ev, kqueue.Filter.Read)) {
                                var reader = conn.client.reader;

                                while (try reader.readMessage()) {
                                    const msg_length = try reader.getMessageLength();
                                    const msg = try self.allocator.alloc(u8, msg_length);
                                    try reader.copyMessage(msg);

                                    std.debug.print("msg: {s}\n", .{msg});
                                    self.allocator.free(msg);
                                }
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

    reader: Reader,
    write_buf: []u8,

    // could put timeout linked list nodes here

    pub fn init(allocator: std.mem.Allocator, socket: net.Socket) !Client {
        const reader = try Reader.init(allocator, socket.fd, 4096);
        const write_buf = try allocator.alloc(u8, 4096);

        return .{
            .socket = socket,
            .alloc = allocator,
            .reader = reader,
            .write_buf = write_buf,
        };
    }

    pub fn create(allocator: std.mem.Allocator, socket: net.Socket) !*Client {
        const client = try allocator.create(Client);
        client.* = try init(allocator, socket);
        return client;
    }

    // TODO: abstract getting a message into the Client

    pub fn deinit(self: Client) void {
        self.reader.deinit();
        self.alloc.free(self.write_buf);
        self.socket.deinit();
    }
};

// NOTE: |Magic Byte (1)|Version (1)|Opcode (1)|Message Len (3)| - Payload length includes the 6 header bytes
// need to redo this with non blocking in mind -- rewrite to save progress when read throws EWOULDBLOCK
// probably want greedy reading
// should return some signal that connection is closed when read returns 0 bytes

pub const Reader = struct {
    allocator: std.mem.Allocator,

    msg_buf: []u8,
    overflow_buf: ?[]u8,
    start: usize,
    pos: usize,
    isFull: bool,
    overflow_pos: usize,

    fd: u64,

    pub fn init(allocator: std.mem.Allocator, fd: u64, buffer_size: usize) !Reader {
        const buf = try allocator.alloc(u8, buffer_size);

        return .{
            .allocator = allocator,
            .msg_buf = buf,
            .overflow_buf = null,
            .start = 4,
            .pos = 4,
            .isFull = false,
            .overflow_pos = 0,
            .fd = fd,
        };
    }

    pub fn deinit(self: Reader) void {
        self.allocator.free(self.msg_buf);

        if (self.overflow_buf) |buf| {
            self.allocator.free(buf);
        }
    }

    fn getInternalSize(self: Reader) usize {
        if (self.isFull) {
            return self.msg_buf.len;
        } else {
            return (self.pos - self.start + self.msg_buf.len) % self.msg_buf.len;
        }
    }

    // Helper function that extracts the message size from the header
    //  even if the header is wrapped around the buffer
    fn getLengthFromHeader(self: Reader) usize {
        std.debug.assert(self.getInternalSize() >= 6); // NOTE: REMOVE THIS IN FINAL VERSION

        const length_start = (self.start + 3) % self.msg_buf.len;

        if (length_start + 3 <= self.msg_buf.len) {

            // collect the length byte slice into fixed array
            const length_bytes: *const [3]u8 = self.msg_buf[length_start .. length_start + 3][0..3];

            // convert byte array to u32
            const message_length: u32 = @intCast(std.mem.readInt(u24, length_bytes, .big));

            return @intCast(message_length);
        } else {
            // Message is on buffer edge
            var length_bytes: [3]u8 = undefined;

            const tail_len = self.msg_buf.len - length_start;
            @memcpy(length_bytes[0..tail_len], self.msg_buf[length_start..self.msg_buf.len]);

            const head_len = 3 - tail_len;
            @memcpy(length_bytes[tail_len..3], self.msg_buf[0..head_len]);

            var message_length: u32 = @intCast(std.mem.readInt(u24, &length_bytes, .big));
            message_length = std.mem.toNative(u32, message_length, .big);
            return @intCast(message_length);
        }
    }

    fn isMessageReady(self: Reader) bool {
        const size = self.getInternalSize();
        if (size < 6) return false;

        const msg_length = self.getLengthFromHeader();

        if (size + self.overflow_pos >= msg_length) return true;

        return false;
    }

    fn getMessageLength(self: Reader) !usize {
        if (!self.isMessageReady()) {
            return error.NoMessage;
        }

        return self.getLengthFromHeader();
    }

    fn copyMessage(self: *Reader, buffer: []u8) !void {
        const msg_length = self.getLengthFromHeader();

        if (buffer.len < msg_length) return error.BufferToSmall;

        var bytes_copied: usize = 0;

        const bytes_inside = if (self.isFull)
            self.msg_buf.len
        else
            (self.pos - self.start + self.msg_buf.len) % self.msg_buf.len;

        const internal_copy_len = @min(msg_length, bytes_inside);

        // copy internal part of message to buffer
        if (self.start + internal_copy_len <= self.msg_buf.len) {
            // Contiguous chunk
            @memcpy(buffer[0..internal_copy_len], self.msg_buf[self.start .. self.start + internal_copy_len]);
            bytes_copied += internal_copy_len;
        } else {
            // Wrapped chunk
            const right_len = self.msg_buf.len - self.start;
            @memcpy(buffer[0..right_len], self.msg_buf[self.start..]);

            const left_len = internal_copy_len - right_len;
            @memcpy(buffer[right_len..internal_copy_len], self.msg_buf[0..left_len]);
            bytes_copied += internal_copy_len;
        }

        // copy overflow to buffer
        if (bytes_copied < msg_length) {
            if (self.overflow_buf) |overflow| {
                const remaining = msg_length - bytes_copied;
                @memcpy(buffer[bytes_copied..msg_length], overflow[0..remaining]);

                // clean up overflow here
                self.allocator.free(overflow);
                self.overflow_buf = null;
                self.overflow_pos = 0;
            } else {
                unreachable;
            }
        }

        // clean up
        self.start = (self.start + internal_copy_len) % self.msg_buf.len;
        self.isFull = false;
    }

    /// Caller should call this in a while loop until it returns false
    pub fn readMessage(self: *Reader) !bool {
        while (!self.isMessageReady()) {
            if (!self.isFull) {
                // read into ring buffer

                // create read buffers for reading into ring buffer
                var bufs: [2][]u8 = undefined;
                var num_bufs: usize = 0;

                if (self.pos < self.start) {
                    bufs[0] = self.msg_buf[self.pos..self.start];
                    num_bufs = 1;
                } else {
                    bufs[0] = self.msg_buf[self.pos..];
                    bufs[1] = self.msg_buf[0..self.start];
                    num_bufs = 2;
                }

                const read_buffers: [][]u8 = bufs[0..num_bufs];

                const bytes_read = net.readv(self.fd, read_buffers) catch |err| {
                    switch (err) {
                        error.WouldBlock => break,
                        else => return err,
                    }
                };

                if (bytes_read == 0) return self.isMessageReady();

                self.pos = (self.pos + bytes_read) % self.msg_buf.len; // update pos, wrapping if needed

                // mark buffer as full if last would make pos == start
                self.isFull = (self.pos == self.start);
            } else {
                // read into overflow

                if (self.overflow_buf == null) {
                    self.overflow_buf = try self.allocator.alloc(u8, self.getLengthFromHeader() - self.msg_buf.len);
                    self.overflow_pos = 0;
                }

                const buf = self.overflow_buf.?; // remove the optional from overflow buf
                self.overflow_pos += net.read(self.fd, buf[self.overflow_pos..]) catch |err| {
                    switch (err) {
                        error.WouldBlock => return false,
                        else => return err,
                    }
                };
            }
        }

        return true;
    }
};
