const std = @import("std");
const thread = std.Thread;
const mutex = std.Io.Mutex;
const expect = std.testing.expect;
const net = @import("net");
const server = @import("server");
const kqueue = @import("kqueue");

const ADDRESS = "127.0.0.1";
const PORT: u16 = 8080;
//const AVAIL_THREADS: usize = 8; // const avail_threads = try std.Thread.getCpuCount(); // check for 3 cores
const ALLOCATOR = std.heap.c_allocator;
const IO = std.testing.io;
const MAX_RESPONSE_TIME = std.Io.Duration.fromMilliseconds(1);
const REST_TIME = std.Io.Duration.fromMilliseconds(500);
const DELAY_TIME = std.Io.Duration.fromMilliseconds(100);
const TIMEOUT_SECS: i64 = 15;

// General Helper Functions

fn startClient(server_address: net.Address) !net.Socket {
    const client = try net.Socket.init(
        net.SocketDomain.Ipv4,
        net.SocketType.Stream,
        0,
        false,
    );

    try client.connect(server_address);
    return client;
}

fn testResponseTime(result: *bool, end_lock: *mutex) !void {
    const address = try net.Address.initIp4WithString(PORT, ADDRESS);

    const test_payload = "Hello, Checks!";
    const test_message: []const u8 = &[_]u8{ 0x4D, 0x01, 0x05, 0x00, 0x00, 0x14 } ++ test_payload;

    var client = try startClient(address);

    defer client.deinit();

    // loop response time check
    while (true) {
        const start_time = std.Io.Timestamp.now(IO, .boot);

        // HACK: whole message might not get written
        _ = try net.write(client.fd, test_message);

        var buf: [1024]u8 = undefined;
        const bytes_read = net.read(client.fd, &buf) catch {
            return;
        };

        if (bytes_read == 0) {
            result.* = false;
            break;
        }

        const end_time = std.Io.Timestamp.now(IO, .boot);
        const elapsed_ns: u64 = @intCast(end_time.toNanoseconds() - start_time.toNanoseconds());

        const isFastEnough = elapsed_ns <= @as(u64, @intCast(MAX_RESPONSE_TIME.toNanoseconds()));

        if (!isFastEnough) {
            result.* = false;
        }

        if (end_lock.*.tryLock()) {
            end_lock.*.unlock(IO);
            return;
        }

        try std.Io.sleep(IO, REST_TIME, .boot);
    }
}

test "Hard Reset" {
    // Have a client connect, send half a message, and then kill the client process with
}

test "One-way Close" {
    // The client sends a complete message and immediately calls shutdown(fd, SHUT_WR) (sending a FIN),
    // but leaves its read-end open. Your server should read the EOF, finish processing the message in
    // the worker thread, flush the response to the client, and then fully close the socket.
}

test "Simple Timeout" {
    // Connect two clients. One sends messages continually and checks for adequate response back,
    // the other waits out the timeout then tests for correct write errors

    // start server
    var sv = try server.Server.init(IO, ALLOCATOR);
    const address = try net.Address.initIp4WithString(PORT, ADDRESS);
    try sv.listen(address);
    const server_thread = try thread.spawn(.{}, server.Server.run, .{&sv});

    const test_payload = "Hello, Server!";
    const test_message: []const u8 = &[_]u8{ 0x4D, 0x01, 0x01, 0x00, 0x00, 0x14 } ++ test_payload;

    // run checker
    var mx = mutex.init;
    var responseResult = true;
    var errorResult = false;

    try mx.lock(IO);
    const checker = try thread.spawn(.{}, testResponseTime, .{ &responseResult, &mx });

    // run tester
    const to_client = try startClient(address);

    // NOTE: Sleep is hardcoded for timeout in src/server/server.zig
    try std.Io.sleep(IO, .fromSeconds(TIMEOUT_SECS + 2), .boot);
    _ = try net.write(to_client.fd, test_message);

    try std.Io.sleep(IO, .fromMilliseconds(10), .boot);

    _ = net.write(to_client.fd, test_message) catch |err| {
        if (err == error.PipeError) {
            errorResult = true;
        } else {
            return err;
        }
    };

    to_client.deinit();

    mx.unlock(IO);
    checker.join();

    sv.stop();
    server_thread.join();

    expect(responseResult) catch |err| {
        const logger = std.log.scoped(.Kqueue);
        logger.err("Control client experienced response drop\n", .{});
        return err;
    };

    expect(errorResult) catch |err| {
        const logger = std.log.scoped(.Kqueue);
        logger.err("Test client was not disconnected\n", .{});
        return err;
    };
}

test "Complex Timeout" {
    var errorResult = false;
    const test_payload = "Hello, Server!";
    const test_message: []const u8 = &[_]u8{ 0x4D, 0x01, 0x01, 0x00, 0x00, 0x14 } ++ test_payload;

    // start server
    var sv = try server.Server.init(IO, ALLOCATOR);
    const address = try net.Address.initIp4WithString(PORT, ADDRESS);
    try sv.listen(address);
    const server_thread = try thread.spawn(.{}, server.Server.run, .{&sv});

    const client1 = try startClient(address);

    try std.Io.sleep(IO, .fromSeconds(2), .boot);

    const client2 = try startClient(address);

    try std.Io.sleep(IO, .fromSeconds(8), .boot);

    _ = try net.write(client1.fd, test_message);

    try std.Io.sleep(IO, .fromSeconds(8), .boot);

    // test client 2
    _ = try net.write(client2.fd, test_message);

    try std.Io.sleep(IO, .fromMilliseconds(10), .boot);

    _ = net.write(client2.fd, test_message) catch |err| {
        if (err == error.PipeError) {
            errorResult = true;
        } else {
            return err;
        }
    };

    client1.deinit();
    client2.deinit();

    sv.stop();
    server_thread.join();

    try expect(errorResult);
}

test "Early Disconnect" {
    // A client connects but disconnects before server accepts the connection
}
