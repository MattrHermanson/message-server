const std = @import("std");
const net = @import("net");
const Allocator = std.mem.Allocator;
const server = @import("server.zig");
const Threadpool = @import("threadpool").Threadpool;

const X25519 = std.crypto.dh.X25519;
const Chacha20 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha512 = std.crypto.kdf.hkdf.HkdfSha256;

const ALLOCATOR = std.heap.c_allocator;

const Opcodes = enum(u8) {
    Handshake = 0x01,
    Authenticate,

    fn check(num: u8, code: Opcodes) bool {
        return num == @intFromEnum(code);
    }
};

fn validate_port(port_str: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, port_str, 10);
    if (port < 1024) return error.WellKnownPort;
    return port;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();

    // validate port number
    const port_str = args.next() orelse {
        std.debug.print("Usage $server [port]\n", .{});
        return 1;
    };

    const port = validate_port(port_str) catch |err| {
        switch (err) {
            error.WellKnownPort => std.debug.print("Invalid Port Number. Cannot use a well-known port\n", .{}),
            else => std.debug.print("Invalid Port Number\n", .{}),
        }

        return 1;
    };

    const address: net.Address = net.Address.initIp4WithString(port, "127.0.0.1") catch |err| {
        std.debug.print("Address Error, {}\n", .{err});
        return 1;
    };

    // var thrd_pool = try Threadpool.create(
    //     io,
    //     std.heap.c_allocator,
    //     try std.Thread.getCpuCount(),
    // );
    // thrd_pool.destroy();

    // TODO: pick better salt
    const keys = X25519.KeyPair.generate(io);
    var salt = [_]u8{ 0x12, 0x34, 0x56, 0x78 };

    var server_state: ServerState = .{
        .keys = keys,
        .salt = salt[0..],
    };

    var sv = try server.Server.init(
        io,
        ALLOCATOR,
        setup,
        handle,
        null,
        .fromSeconds(60),
        &server_state,
    );

    try sv.listen(address);

    sv.run() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };

    return 0;
}

// setup func level client structs and send server's pub key
fn setup(udata: ?*anyopaque, client: *server.Client) server.HandlerFnError!void {
    client.udata = ALLOCATOR.create(Client) catch return error.Unrecoverable;

    if (client.udata) |raw_ptr| {
        if (udata) |raw_udata_ptr| {
            const clnt: *Client = @ptrCast(@alignCast(raw_ptr));
            const state: *ServerState = @ptrCast(@alignCast(raw_udata_ptr));

            clnt.status = .New;

            // send server's pub key
            client.write(0x1, &state.keys.public_key) catch return;
            // TODO: what should hap when pub key doesn't get sent??
        }
    }
}

// NOTE: HEADER: |Magic Byte (1)|Version (1)|Opcode (1)|Message Len (3)| - Message length includes header bytes
//       Message: |Nonce (12)|Tag (16)|Msg... |

fn handle(udata: ?*anyopaque, client: *server.Client, msg: []u8) server.HandlerFnError!bool {
    if (client.udata) |raw_ptr| {
        if (udata) |raw_udata_ptr| {
            const clnt: *Client = @ptrCast(@alignCast(raw_ptr));
            const state: *ServerState = @ptrCast(@alignCast(raw_udata_ptr));

            // don't continue if secure connection & authentication not established
            if (!try securityHandler(clnt, state, msg)) return false;

            const decrypted_msg = decrypt(client.allocator, clnt, msg) catch {
                return error.Unrecoverable;
            };

            std.debug.print("Encrypted msg: {s}\n", .{msg});
            std.debug.print("Decrypted msg: {s}\n", .{decrypted_msg});

            return false;
        } else return error.Unrecoverable;
    } else return error.Unrecoverable;
}

//fn onComplete(udata: ?*anyopaque, client: *server.Client) server.HandlerFnError!bool {}

// returns true/false if server code should continue
fn securityHandler(client: *Client, state: *ServerState, msg: []u8) server.HandlerFnError!bool {
    switch (client.status) {
        .New => {
            var client_pub_key: [32]u8 = undefined;

            // check opcode
            if (Opcodes.check(msg[2], .Handshake)) {
                @memcpy(&client_pub_key, msg[6..38]);

                // compute shared secret
                const shared_secret = X25519.scalarmult(state.keys.secret_key, client_pub_key) catch {
                    return error.Unrecoverable;
                };

                // compute key
                const prk = Sha512.extract(state.salt, &shared_secret);
                client.key = std.heap.c_allocator.alloc(u8, 32) catch return error.Unrecoverable;
                Sha512.expand(client.key, "session", prk);

                client.status = .Established;
                return false;
            }

            return false;
        },
        .Established => {
            if (Opcodes.check(msg[2], .Authenticate)) {
                // receive user and password
                return true; // TODO: implement passwd handling, this is for testing

            } else {
                return false; // TODO: send Error Not Authenticated
            }
        },
        .Authenticated => return true,
    }
}

const ServerState = struct {
    keys: X25519.KeyPair,
    salt: []u8,
};

const Status = enum {
    New,
    Established,
    Authenticated,
};

const Client = struct {
    status: Status,
    key: []u8,
};

/// returns a message that is encrypted with nonce & tag prepended
/// note: nonce must be incremented after calling
fn encrypt(allocator: Allocator, unencrypted_msg: []u8, nonce: [12]u8, key: [32]u8) ![]u8 {
    // TODO: check network byte order
    var encrypted_msg: []u8 = allocator.alloc(u8, unencrypted_msg.len + 28);
    var tag: [16]u8 = undefined;

    Chacha20.encrypt(&encrypted_msg[28..], &tag, unencrypted_msg, &[_]u8{}, nonce, key);

    @memcpy(encrypted_msg, nonce);
    @memcpy(encrypted_msg[12..], tag);
    return encrypted_msg;
}

fn decrypt(allocator: Allocator, client: *Client, encrypted_msg: []u8) ![]u8 {
    const decrypted_msg = try allocator.alloc(u8, encrypted_msg.len - 34);

    const tag: [16]u8 = encrypted_msg[18..34].*;
    const nonce: [12]u8 = encrypted_msg[6..18].*;

    try Chacha20.decrypt(decrypted_msg, encrypted_msg[34..], tag, &[_]u8{}, nonce, client.key[0..32].*);

    return decrypted_msg;
}
