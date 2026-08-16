const std = @import("std");
const thread = std.Thread;
const mutex = std.Io.Mutex;
const expect = std.testing.expect;
const net = @import("net");
const server = @import("server");
const kqueue = @import("kqueue");

// NOTE: |Magic Byte (1)|Version (1)|Opcode (1)|Message Len (3)| - Payload length includes the 6 header bytes

const ADDRESS = "127.0.0.1";
const PORT: u16 = 8080;

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

/// Spawns num_threads testers running test_fn and one thread running check_fn
/// test_fn must perform whatever stress/error/whatever testing
/// check_fn must verify server is responding correctly and update result once it can lock end_lock
fn dispatchTest(comptime num_threads: u8, comptime test_fn: anytype, test_args: anytype, comptime check_fn: anytype) !bool {
    var mx = mutex.init;
    var result: bool = true;

    // lock mutex and run checker, checker will try to lock every loop
    try mx.lock(std.testing.io);
    const checker = try thread.spawn(.{}, check_fn, .{ &result, &mx });

    // spin up tester threads
    var tester_threads: [num_threads]thread = undefined;

    for (&tester_threads) |*thrd| {
        thrd.* = try thread.spawn(.{}, test_fn, test_args);
    }

    for (tester_threads) |thrd| {
        thrd.join();
    }

    // unlock mutex to signal to checker that testers finished
    mx.unlock(std.testing.io);
    checker.join();

    return result;
}

// TESTS BELOW (test, then that tests helpers)

test "Slow Reads" {
    // have N threads send slow messages
    // have another thread check that it

    const allocator = std.heap.c_allocator;
    const avail_threads: usize = 8; //const avail_threads = try std.Thread.getCpuCount(); // check for 3 cores

    // start server
    var sv = try server.Server.init(allocator);
    defer sv.deinit();
    const address = try net.Address.initIp4WithString(PORT, ADDRESS);
    try sv.listen(address);
    const server_thread = try thread.spawn(.{}, server.Server.run, .{&sv});

    const test_payload = "Hello, Server!";
    const test_message: []const u8 = &[_]u8{
        0x4D, // Magic Byte (e.g., 'M')
        0x01, // Version (1)
        0x01, // Opcode (e.g., 5)
        0x00, 0x00, 0x14, // Message Length (20)
    } ++ test_payload;

    // run tests
    const result = try dispatchTest(
        avail_threads - 2,
        slowSend,
        .{
            std.testing.io,
            2,
            std.Io.Duration.fromMilliseconds(50),
            std.Io.Duration.fromMilliseconds(100),
            test_message,
        },
        testResponseTime,
    );

    sv.stop();
    server_thread.join();

    try expect(result);
}

fn slowSend(io: std.Io, n: u32, delay: std.Io.Duration, rest: std.Io.Duration, msg: []const u8) void {
    const address = net.Address.initIp4WithString(PORT, ADDRESS) catch {
        return;
    };

    const client = startClient(address) catch {
        return;
    };
    defer client.deinit();

    const halfway = msg.len / 2;
    const first_part = msg[0..halfway];
    const second_part = msg[halfway..];

    for (0..n) |_| {
        _ = net.write(client.fd, first_part) catch {
            return;
        };
        std.Io.sleep(io, delay, .boot) catch {
            return;
        };
        _ = net.write(client.fd, second_part) catch {
            return;
        };
        std.Io.sleep(io, rest, .boot) catch {
            return;
        };
    }
}

fn testResponseTime(result: *bool, end_lock: *mutex) void {
    const max_duration = std.Io.Duration.fromMilliseconds(1);

    const address = net.Address.initIp4WithString(PORT, ADDRESS) catch {
        result.* = false;
        return;
    };

    const test_payload = "Hello, Server!";
    const test_message: []const u8 = &[_]u8{
        0x4D, // Magic Byte
        0x01, // Version
        0x05, // Opcode
        0x00, 0x00, 0x14, // Msg Length
    } ++ test_payload;

    var client = startClient(address) catch {
        return;
    };

    defer client.deinit();

    // loop response time check
    while (true) {
        const start_time = std.Io.Timestamp.now(std.testing.io, .boot);

        _ = net.write(client.fd, test_message) catch { // HACK: whole message might not get written
            return;
        };

        var buf: [1024]u8 = undefined;
        const bytes_read = net.read(client.fd, &buf) catch {
            return;
        };

        if (bytes_read == 0) {
            result.* = false;
            break;
        }

        const end_time = std.Io.Timestamp.now(std.testing.io, .boot);
        const elapsed_ns: u64 = @intCast(end_time.toNanoseconds() - start_time.toNanoseconds());

        const isFastEnough = elapsed_ns <= @as(u64, @intCast(max_duration.toNanoseconds()));

        if (!isFastEnough) {
            result.* = false;
        }

        if (end_lock.*.tryLock()) {
            end_lock.*.unlock(std.testing.io);
            return;
        }

        std.Io.sleep(std.testing.io, .fromMilliseconds(50), .boot) catch {
            return;
        };
    }
}

test "Header Pause" {
    // send partial headers then wait
}

test "Internal Buffer Straddling" {
    // if buf 4096 bytes, send 4095, 4096, 4097 bytes
    // send two messages together with the 2nd's header
    //      spanning into overflow
}

test "Greedy Reads" {
    // send many small messages to test greedy reading
}
