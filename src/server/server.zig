const std = @import("std");
const net = @import("net");
const kqueue = @import("kqueue");

const BACKLOG_MAX = 128;
const KQUEUE_SIZE = 128;

// TODO: let setup return an error, so server can close conn
//          if layer above isn't able to do what it needs todo
// TODO: remove Opcode from header
// BUG: udata in Client does not get free on close
// TODO: figure out way to tell layer above that server is closing connection

const Connection = struct {
    next: ?*Connection,
    prev: ?*Connection,

    type: union(enum) { // not sure about this name (maybe data???)
        listener: *net.Socket,
        client: *Client,
    },

    timeout: std.Io.Timestamp,

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        switch (self.type) {
            .listener => |listener| {
                listener.deinit();
                allocator.destroy(listener);
            },
            .client => |client| {
                client.deinit();
                allocator.destroy(client);
            },
        }

        allocator.destroy(self);
    }

    pub fn addToDList(self: *Connection, head: *?*Connection, tail: *?*Connection) void {
        if (head.* == null) {
            head.* = self;
            tail.* = self;
        } else {
            if (tail.*) |tail_conn| {
                tail_conn.next = self;
                self.prev = tail.*;
                tail.* = self;
            }
        }
    }

    pub fn removeFromDList(self: *Connection, head: *?*Connection, tail: *?*Connection) void {
        if (self.prev) |prev| {
            prev.next = self.next;
        } else {
            head.* = self.next;
        }

        if (self.next) |next| {
            next.prev = self.prev;
        } else {
            tail.* = self.prev;
        }

        self.next = null;
        self.prev = null;
    }
};

pub const HandlerFnError = error{
    Unrecoverable,
};

/// To start server, init() -> listen() -> run()
/// setup() is run when the connection is accepted
/// handle() runs whenever a complete message has been received, caller is
///     responsible for freeing msg when done with is using client.allocator.free()
/// onComplete() gets called when EVFILT_USER is triggered. It can be used
///     to do something after asynchronous work, dispatched from handle(),
///     is finished
/// Handler functions can return true to close that client's connection as
///     a result of intented behavior
/// Handler functions can return HandlerFnError.Unrecoverable to close a
///     a connection as a result of an unrecoverable error
pub const Server = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    kq: kqueue.Kqueue,
    running: std.atomic.Value(bool),
    head_connection: ?*Connection,
    tail_connection: ?*Connection,
    setup: ?*const fn (udata: ?*anyopaque, client: *Client) HandlerFnError!void,
    handle: *const fn (udata: ?*anyopaque, client: *Client, msg: []u8) HandlerFnError!bool,
    onComplete: ?*const fn (udata: ?*anyopaque, client: *Client) HandlerFnError!bool,
    timeout: std.Io.Duration,
    udata: ?*anyopaque, // will NOT be modified by any internal code

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        setup: ?*const fn (udata: ?*anyopaque, client: *Client) HandlerFnError!void,
        handle: *const fn (udata: ?*anyopaque, client: *Client, msg: []u8) HandlerFnError!bool,
        onComplete: ?*const fn (udata: ?*anyopaque, client: *Client) HandlerFnError!bool,
        timeout: std.Io.Duration,
        udata: ?*anyopaque,
    ) !Server {
        return .{
            .io = io,
            .allocator = allocator,
            .kq = try kqueue.Kqueue.initWithSize(allocator, KQUEUE_SIZE),
            .running = std.atomic.Value(bool).init(true),
            .head_connection = null,
            .tail_connection = null,
            .setup = setup,
            .handle = handle,
            .onComplete = onComplete,
            .timeout = timeout,
            .udata = udata,
        };
    }

    fn deinit(self: *Server) void {
        self.kq.deinit();

        while (self.head_connection) |connection| {
            self.head_connection = connection.next;
            connection.deinit(self.allocator);
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
            .next = null,
            .prev = null,
            .type = .{
                .listener = listener_ptr,
            },
            .timeout = .{ .nanoseconds = 0 },
        };

        // add listener to list
        listener_conn.addToDList(&self.head_connection, &self.tail_connection);

        const event = kqueue.Kevent{
            .identifier = @intCast(listener_ptr.fd),
            .filter = @intFromEnum(kqueue.Filter.Read),
            .flags = @intFromEnum(kqueue.Flag.Add),
            .fflags = 0,
            .data = 0,
            .udata = @ptrCast(listener_conn),
        };

        _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false, null);
    }

    // HACK: server should handle not return errors
    pub fn run(self: *Server) !void {
        while (self.running.load(.acquire)) {
            var timeout = try self.getTimeout();
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
                            const new_client = try Client.create(
                                self.allocator,
                                new_conn,
                                new_socket,
                                &self.kq,
                            );

                            new_conn.* = .{
                                .next = null,
                                .prev = null,
                                .type = .{
                                    .client = new_client,
                                },
                                .timeout = .now(self.io, .boot),
                            };
                            new_conn.timeout = new_conn.timeout.addDuration(self.timeout);

                            // add connection to end of list
                            new_conn.addToDList(&self.head_connection, &self.tail_connection);

                            const event = kqueue.Kevent{
                                .identifier = new_conn.type.client.socket.fd,
                                .filter = @intFromEnum(kqueue.Filter.Read),
                                .flags = @intFromEnum(kqueue.Flag.Add),
                                .fflags = 0,
                                .data = 0,
                                .udata = @ptrCast(new_conn),
                            };

                            if (self.setup) |setup| {
                                setup(self.udata, new_client) catch {
                                    // FIX: need to close connection here
                                };
                            }

                            // register event with kq
                            _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false, null);
                        },
                        .client => |client| {
                            // client is ready

                            // reset timestamp
                            conn.timeout = .now(self.io, .boot);
                            conn.timeout = conn.timeout.addDuration(self.timeout);
                            conn.removeFromDList(&self.head_connection, &self.tail_connection);
                            conn.addToDList(&self.head_connection, &self.tail_connection);

                            var should_close = false;

                            if (kqueue.checkFlag(ev, kqueue.Flag.EOF)) {
                                should_close = true;
                            }

                            // Read
                            if (kqueue.checkFilter(ev, kqueue.Filter.Read)) {
                                while (true) {
                                    const message = client.read() catch |err| {
                                        switch (err) {
                                            error.ConnectionClosed, error.ConnectionReset => {
                                                should_close = true;
                                                break;
                                            },
                                            else => return err,
                                        }
                                    };

                                    // handle message or break because all msgs are read
                                    if (message) |msg| {
                                        should_close = should_close or self.handle(self.udata, client, msg) catch true;
                                    } else break;
                                }
                            }

                            // User
                            if (self.onComplete) |onComplete| {
                                if (kqueue.checkFilter(ev, kqueue.Filter.User)) {
                                    should_close = should_close or onComplete(self.udata, client) catch true;
                                }
                            }

                            // Write
                            if (kqueue.checkFilter(ev, kqueue.Filter.Write)) {
                                client.flush() catch |err| {
                                    if (err == error.SocketNotConnected or err == error.PipeError) {
                                        should_close = true;
                                    }
                                };
                            }

                            // Close connection
                            if (should_close) {
                                self.closeConnection(conn);
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

    fn closeConnection(self: *Server, conn: *Connection) void {
        conn.removeFromDList(&self.head_connection, &self.tail_connection);

        conn.deinit(self.allocator);
    }

    fn getTimeout(self: *Server) !kqueue.Timespec {
        const now = std.Io.Timestamp.now(self.io, .boot);

        var node = self.head_connection;
        while (node) |n| {

            // break for listening sockets
            if (n.timeout.nanoseconds == 0) {
                node = n.next;
                continue;
            }

            const diff = now.durationTo(n.timeout);
            if (diff.nanoseconds > 0) {
                const uns = @as(u96, @intCast(diff.nanoseconds));

                const sec = @as(u64, @intCast(uns / std.time.ns_per_s));
                const nsec = @as(u64, @intCast(uns % std.time.ns_per_s));

                return .{ .sec = sec, .nsec = nsec };
            }

            // remove timeouts in the past
            const event = kqueue.Kevent{
                .identifier = n.type.client.socket.fd,
                .filter = @intFromEnum(kqueue.Filter.Read),
                .flags = @intFromEnum(kqueue.Flag.Delete),
                .fflags = 0,
                .data = 0,
                .udata = @ptrCast(n),
            };

            // remove event from kq
            _ = try self.kq.kevent(&[_]kqueue.Kevent{event}, false, null);

            node = n.next;
            self.closeConnection(n);
        }

        return .{ .sec = 0, .nsec = 50_000_000 }; // NOTE: this is only here for atomic variable stopping
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,

    conn: *Connection,
    socket: net.Socket,
    kq: *kqueue.Kqueue,

    reader: Reader,
    writer: Writer,

    udata: ?*anyopaque, // will NOT be modified by any internal code

    pub fn init(allocator: std.mem.Allocator, conn: *Connection, socket: net.Socket, kq: *kqueue.Kqueue) !Client {
        const reader = try Reader.init(allocator, socket.fd, 4096);
        const writer = Writer.init(allocator, socket.fd);

        return .{
            .allocator = allocator,
            .conn = conn,
            .socket = socket,
            .kq = kq,
            .reader = reader,
            .writer = writer,
            .udata = null,
        };
    }

    pub fn create(allocator: std.mem.Allocator, conn: *Connection, socket: net.Socket, kq: *kqueue.Kqueue) !*Client {
        const client = try allocator.create(Client);
        client.* = try init(allocator, conn, socket, kq);
        return client;
    }

    pub fn deinit(self: *Client) void {
        self.reader.deinit();
        self.writer.deinit();
        self.socket.deinit();
    }

    /// Dispatches a user signal for this client
    pub fn signal(self: Client) void {
        // TODO: To actually trigger the event, you typically need to pass NOTE_TRIGGER (often 0x01)
        // to fflags depending on your specific kqueue wrapper's implementation
        const event = kqueue.Kevent{
            .identifier = self.socket.fd,
            .filter = @intFromEnum(kqueue.Filter.User),
            .flags = @intFromEnum(kqueue.Flag.Add) | @intFromEnum(kqueue.Flag.Clear),
            .fflags = 0,
            .data = 0,
            .udata = @ptrCast(self.conn),
        };

        // Register the event with kqueue
        _ = self.kq.kevent(&[_]kqueue.Kevent{event}, false, null) catch |err| {
            std.debug.print("Failed to register user event: {}\n", .{err});
        };
    }

    // IDEA: could return a message with header fields and body split
    pub fn read(self: *Client) !?[]u8 {
        const isMessageReady = try self.reader.readMessage();

        if (!isMessageReady) return null;

        const msg_length = try self.reader.getMessageLength();
        const msg = try self.allocator.alloc(u8, msg_length);
        try self.reader.copyMessage(msg);
        return msg;
    }

    pub fn write(self: *Client, opcode: u8, msg: []const u8) !void {
        const msg_len: u24 = @intCast(msg.len);
        var header: [6]u8 = undefined;

        header[0] = 0x4D;
        header[1] = 0x01;
        header[2] = opcode;
        std.mem.writeInt(u24, header[3..], msg_len + 6, .big);

        try self.writer.writeMessage(self.kq, header[0..], msg, self.conn);
    }

    pub fn flush(self: *Client) !void {
        try self.writer.flush(self.kq, self.conn);
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
    data: []u8,
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
    pub fn writeMessage(self: *Writer, kq: *kqueue.Kqueue, header: []u8, msg: []const u8, connection: *Connection) !void {

        // TODO: use object pool for messages
        const new_out_msg = try self.allocator.create(OutMsg);
        new_out_msg.data = try self.allocator.alloc(u8, msg.len + 6);
        @memcpy(new_out_msg.data[0..6], header);
        @memcpy(new_out_msg.data[6..], msg);

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
