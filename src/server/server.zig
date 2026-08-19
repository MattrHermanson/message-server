const std = @import("std");
const net = @import("net");
const kqueue = @import("kqueue");

// NOTE: current goal -> be able to handle N clients with a kqueue

const BACKLOG_MAX = 128;
const KQUEUE_SIZE = 128;

const Connection = struct {
    next: ?*Connection,
    prev: ?*Connection,

    type: union(enum) { // not sure about this name (maybe data???)
        listener: *net.Socket,
        client: *Client,
    },

    /// assumes nodes are prepended
    pub fn removeConnection(self: *Connection, head: *?*Connection) void {
        const next = self.next;
        const prev = self.prev;

        if (prev) |p| {
            p.next = next;
        } else {
            head.* = next;
        }

        if (next) |n| {
            n.prev = prev;
        }

        self.next = null;
        self.prev = null;
    }
};

/// To start server, init() -> listen() -> run()
pub const Server = struct {
    allocator: std.mem.Allocator,
    kq: kqueue.Kqueue,
    running: std.atomic.Value(bool),
    active_connections: ?*Connection,

    pub fn init(allocator: std.mem.Allocator) !Server {
        return .{
            .allocator = allocator,
            .kq = try kqueue.Kqueue.initWithSize(allocator, KQUEUE_SIZE),
            .running = std.atomic.Value(bool).init(true),
            .active_connections = null,
        };
    }

    fn deinit(self: *Server) void {
        self.kq.deinit();

        while (self.active_connections) |connection| {
            switch (connection.type) {
                .listener => |listener| {
                    listener.deinit();
                    self.allocator.destroy(listener);
                },
                .client => |client| {
                    client.deinit();
                    self.allocator.destroy(client);
                },
            }

            self.active_connections = connection.next;
            self.allocator.destroy(connection);
        }
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
        const listener_conn = try self.allocator.create(Connection);
        listener_conn.* = .{
            .next = self.active_connections,
            .prev = null,
            .type = .{
                .listener = listener_ptr,
            },
        };

        if (self.active_connections) |active| {
            active.prev = listener_conn;
        }
        self.active_connections = listener_conn;

        const event = kqueue.Kevent{
            .identifier = @intCast(listener_ptr.fd),
            .filter = @intFromEnum(kqueue.Filter.Read),
            .flags = @intFromEnum(kqueue.Flag.Add),
            .fflags = 0,
            .data = 0,
            .udata = @ptrCast(self.active_connections),
        };

        _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false, null);
    }

    // HACK: server should handle not return errors
    pub fn run(self: *Server) !void {
        var timeout = kqueue.Timespec{ .sec = 0, .nsec = 50_000_000 };

        while (self.running.load(.acquire)) {
            const ready_list = try self.kq.kevent(&.{}, true, &timeout);

            for (ready_list) |ev| {
                if (ev.udata) |raw_ptr| {
                    const conn: *Connection = @ptrCast(@alignCast(raw_ptr));

                    switch (conn.*.type) {
                        .listener => |listener| {
                            // listener is ready

                            // TODO: use object pool to allocate connections

                            // accept connection and pack connection union into udata
                            const new_socket = try listener.*.accept(true); // TODO: loop until accept would block
                            const new_conn = try self.allocator.create(Connection);
                            const new_client = try Client.create(self.allocator, new_socket);

                            new_conn.* = .{
                                .next = self.active_connections,
                                .prev = null,
                                .type = .{
                                    .client = new_client,
                                },
                            };

                            if (self.active_connections) |active_connections| {
                                active_connections.prev = new_conn;
                            }
                            self.active_connections = new_conn;

                            const event = kqueue.Kevent{
                                .identifier = new_conn.type.client.socket.fd,
                                .filter = @intFromEnum(kqueue.Filter.Read),
                                .flags = @intFromEnum(kqueue.Flag.Add),
                                .fflags = 0,
                                .data = 0,
                                .udata = @ptrCast(new_conn),
                            };

                            // register event with kq
                            _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false, null);
                        },
                        .client => |client| {
                            // client is ready

                            var should_close = false;

                            if (kqueue.checkFlag(ev, kqueue.Flag.EOF)) {
                                should_close = true;
                            }

                            // Read
                            if (kqueue.checkFilter(ev, kqueue.Filter.Read)) {
                                var reader = &client.reader;

                                while (true) {
                                    const isMessageReady = reader.readMessage() catch |err| {
                                        switch (err) {
                                            error.ConnectionClosed, error.ConnectionReset => {
                                                should_close = true;
                                                break;
                                            },
                                            else => return err,
                                        }
                                    };

                                    if (!isMessageReady) break;

                                    const msg_length = try reader.getMessageLength();
                                    const msg = try self.allocator.alloc(u8, msg_length);
                                    try reader.copyMessage(msg);

                                    try client.writer.writeMessage(&self.kq, msg, conn);
                                    self.allocator.free(msg);
                                }
                            }

                            // Write
                            if (kqueue.checkFilter(ev, kqueue.Filter.Write)) {
                                client.writer.flush(&self.kq, conn) catch |err| {
                                    if (err == error.SocketNotConnected or err == error.PipeError) {
                                        should_close = true;
                                    }
                                };
                            }

                            // Close connection
                            if (should_close) {
                                // conn.removeConnection(&self.active_connections);
                                //
                                // client.deinit();
                                // self.allocator.destroy(client);
                                // self.allocator.destroy(conn);
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

        self.deinit();
    }

    /// Stops the server and cleans up
    pub fn stop(self: *Server) void {
        self.running.store(false, .release);
    }
};

pub const Client = struct {
    socket: net.Socket,

    alloc: std.mem.Allocator,

    reader: Reader,
    writer: Writer,

    // could put timeout linked list nodes here

    pub fn init(allocator: std.mem.Allocator, socket: net.Socket) !Client {
        const reader = try Reader.init(allocator, socket.fd, 4096);
        const writer = Writer.init(allocator, socket.fd);

        return .{
            .socket = socket,
            .alloc = allocator,
            .reader = reader,
            .writer = writer,
        };
    }

    pub fn create(allocator: std.mem.Allocator, socket: net.Socket) !*Client {
        const client = try allocator.create(Client);
        client.* = try init(allocator, socket);
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.reader.deinit();
        self.writer.deinit();
        self.socket.deinit();
    }
};

// NOTE: |Magic Byte (1)|Version (1)|Opcode (1)|Message Len (3)| - Payload length includes the 6 header bytes

/// if readMessage() returns true, find out how much to allocate from getMessageLength(),
/// then call copyMessage() to pull the message out of Reader
pub const Reader = struct {

    // TODO: Consider rewriting to use a buffer pool, and chain buffers for larger msgs

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
            return (self.pos + self.msg_buf.len - self.start) % self.msg_buf.len;
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

            const message_length: u32 = @intCast(std.mem.readInt(u24, &length_bytes, .big));
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
            (self.pos + self.msg_buf.len - self.start) % self.msg_buf.len;

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
                        error.WouldBlock => return false,
                        else => return err,
                    }
                };

                if (bytes_read == 0) return error.ConnectionClosed; // was isMessageReady()

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

// FLOW
// call writeMessage() passing a message into the Writer
//      w/ the expectation that the message will get written
//
// writeMessage() queues the message into a linked list of messages
//      to be sent, and sets write notifs for the kevent
//
// every kevent returns with the write flagged, call flush()

// FUNCTION REQUIREMENTS
// writeMessage()
// - takes kqueue to register socket for write notifs
//
// flush()
// - takes kqueue to unregister socket for write notifs

const OutMsg = struct {
    data: []const u8,
    sent_bytes: usize = 0,
    next: ?*OutMsg = null,
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    fd: u64,

    // HACK: add max outgoing messages

    head_msg: ?*OutMsg,
    tail_msg: ?*OutMsg,

    pub fn init(allocator: std.mem.Allocator, fd: u64) Writer {
        return .{
            .allocator = allocator,
            .fd = fd,
            .head_msg = null,
            .tail_msg = null,
        };
    }

    pub fn deinit(self: *Writer) void {
        while (self.head_msg) |msg| {
            self.head_msg = msg.next;
            self.allocator.destroy(msg);
        }
    }

    /// pushes messages to the queue, msg must have a correctly formatted header
    /// msg will be copied internally, caller is responsible for freeing the buffer passed in
    pub fn writeMessage(self: *Writer, kq: *kqueue.Kqueue, msg: []const u8, connection: *Connection) !void {

        // TODO: use object pool for messages
        const new_out_msg = try self.allocator.create(OutMsg);
        new_out_msg.data = try self.allocator.dupe(u8, msg);
        new_out_msg.sent_bytes = 0;
        new_out_msg.next = null;

        if (self.head_msg == null) {
            self.head_msg = new_out_msg;
            self.tail_msg = new_out_msg;
        } else {
            if (self.tail_msg) |tail_msg| {
                tail_msg.next = new_out_msg;
                self.tail_msg = new_out_msg;
            }
        }

        const event = kqueue.Kevent{
            .identifier = connection.type.client.socket.fd,
            .filter = @intFromEnum(kqueue.Filter.Write),
            .flags = @intFromEnum(kqueue.Flag.Add),
            .fflags = 0,
            .data = 0,
            .udata = @ptrCast(connection),
        };

        // register event with kq
        _ = try kq.kevent(&[_]kqueue.Kevent{event}, false, null);
        try self.flush(kq, connection);
    }

    // writes (somtimes partially) messages to the socket, popping msgs
    pub fn flush(self: *Writer, kq: *kqueue.Kqueue, connection: *Connection) !void {

        // TODO: use writev to write OutMsg queue

        // write until head is null or write would block
        while (self.head_msg) |head| {
            const bytes_written = net.write(self.fd, head.data[head.sent_bytes..]) catch |err| {
                switch (err) {
                    error.WouldBlock => return,
                    else => return err,
                }
            };

            head.sent_bytes += bytes_written;

            // free head and advance queue
            if (head.sent_bytes == head.data.len) {
                self.head_msg = head.next;
                if (self.head_msg == null) {
                    self.tail_msg = null;
                }

                self.allocator.free(head.data);
                self.allocator.destroy(head);
            }
        }

        // if head is null remove write from kqueue
        const event = kqueue.Kevent{
            .identifier = connection.type.client.socket.fd,
            .filter = @intFromEnum(kqueue.Filter.Write),
            .flags = @intFromEnum(kqueue.Flag.Disable),
            .fflags = 0,
            .data = 0,
            .udata = @ptrCast(connection),
        };

        // register event with kq
        _ = try kq.kevent(&[_]kqueue.Kevent{event}, false, null);
    }
};
