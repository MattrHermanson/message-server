const std = @import("std");
const net = @import("net");
const Allocator = std.mem.Allocator;
const server = @import("server.zig");
const Threadpool = @import("threadpool").Threadpool;
const db = @import("db");
const parser = @import("parser.zig");

const X25519 = std.crypto.dh.X25519;
const Chacha20 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha512 = std.crypto.kdf.hkdf.HkdfSha256;
const Argon2 = std.crypto.pwhash.argon2;

const expect = std.testing.expect;

const ALLOCATOR = std.heap.c_allocator;

fn validate_port(port_str: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, port_str, 10);
    if (port < 1024) return error.WellKnownPort;
    return port;
}

// TODO: implement response message for client actions
// TODO: rewrite securityHandler to handoff tasks to threadpool
// TODO: check that encrypted and decrypted msgs are getting freed

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
    var nonce_counter: u96 = 0;

    var database = try db.Database.init(io, ALLOCATOR, "./store.db", "./src/sql/setup.sql");

    var server_state: ServerState = .{
        .keys = keys,
        .salt = salt[0..],
        .db = &database,
        .io = io,
        .nonce = &nonce_counter,
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

/// setup client state and send server's pub key
fn setup(udata: ?*anyopaque, s_client: *server.Client) server.HandlerFnError!void {
    s_client.udata = ALLOCATOR.create(Client) catch return error.Unrecoverable;

    if (s_client.udata) |raw_ptr| {
        if (udata) |raw_udata_ptr| {
            const clnt: *Client = @ptrCast(@alignCast(raw_ptr));
            const state: *ServerState = @ptrCast(@alignCast(raw_udata_ptr));

            clnt.status = .New;

            // send server's pub key
            s_client.write(0x1, &state.keys.public_key) catch {
                return error.Unrecoverable;
            };
        }
    }
}

// NOTE: HEADER: |Magic Byte (1)|Version (1)|Opcode (1)|Message Len (3)| - Message length includes header bytes
//       Message: |Nonce (12)|Tag (16)|Msg... |

/// create secure connection, authenticate, then proceed with operation execution
/// returns true/false to signal that client shouldClose
/// returns Unrecoverable if an error halts operation execution
fn handle(udata: ?*anyopaque, s_client: *server.Client, msg: []u8) server.HandlerFnError!bool {
    if (s_client.udata) |raw_client_ptr| {
        if (udata) |raw_state_ptr| {
            const client: *Client = @ptrCast(@alignCast(raw_client_ptr));
            const state: *ServerState = @ptrCast(@alignCast(raw_state_ptr));

            std.debug.print("received message\n", .{});

            // DON'T CONTINUE if secure connection & authentication not established
            const decrypted_msg = securityHandler(s_client, client, state, msg) catch |err| {
                switch (err) {
                    error.Unrecoverable => return error.Unrecoverable,
                    error.NotAuthenticated => return false,
                }
            };

            std.debug.print("Encrypted msg: {s}\n", .{msg});
            std.debug.print("Decrypted msg: {s}\n", .{decrypted_msg});

            return false;
        } else return error.Unrecoverable;
    } else return error.Unrecoverable;
}

//fn onComplete(udata: ?*anyopaque, client: *server.Client) server.HandlerFnError!bool {}

// Message-Server Logic
const ServerState = struct {
    keys: X25519.KeyPair,
    salt: []u8,
    db: *db.Database,
    io: std.Io,
    nonce: *u96,
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

/// carries out security protocols for all client statuses
/// returns the decrypted header+message
/// returns NotAuthenticated when connection isn't encrypted or authenticated
/// returns Unrecoverable if the connection must be closed
fn securityHandler(s_client: *server.Client, client: *Client, state: *ServerState, msg: []u8) ![]u8 {
    switch (client.status) {
        .New => {
            // check opcode
            if (parser.Opcodes.check(msg[2], .Handshake)) {
                const handshake = parser.Handshake.parse(msg) catch {
                    sendUnsecureResp(s_client, parser.ResponseCodes.BadMessage) catch {
                        return error.Unrecoverable;
                    };
                    return error.NotAuthenticated;
                };

                // convert to 32 byte array
                var client_pub_key: [32]u8 = undefined;
                @memcpy(&client_pub_key, handshake.pub_key);

                // compute shared secret
                const shared_secret = X25519.scalarmult(state.keys.secret_key, client_pub_key) catch {
                    return error.Unrecoverable;
                };

                // compute key
                const prk = Sha512.extract(state.salt, &shared_secret);
                client.key = ALLOCATOR.alloc(u8, 32) catch return error.Unrecoverable;
                Sha512.expand(client.key, "session", prk);

                client.status = .Established;
                return error.NotAuthenticated;
            } else {
                sendUnsecureResp(s_client, parser.ResponseCodes.NotSecure) catch {
                    return error.Unrecoverable;
                };

                return error.NotAuthenticated;
            }
        },
        .Established => {
            switch (@as(parser.Opcodes, @enumFromInt(msg[2]))) {
                .Register => {
                    const decrypted_msg = decrypt(ALLOCATOR, client, msg) catch {
                        sendSecureResp(
                            ALLOCATOR,
                            s_client,
                            client,
                            state.nonce,
                            parser.ResponseCodes.BadMessage,
                        ) catch return error.Unrecoverable;

                        return error.NotAuthenticated;
                    };

                    const register = parser.Register.parse(decrypted_msg) catch {
                        sendSecureResp(
                            ALLOCATOR,
                            s_client,
                            client,
                            state.nonce,
                            parser.ResponseCodes.BadMessage,
                        ) catch return error.Unrecoverable;

                        return error.NotAuthenticated;
                    };

                    // hash plaintext password
                    const params = std.crypto.pwhash.argon2.Params{
                        .m = 19456, // Memory cost (16 MiB)
                        .t = 2, // Time cost in iterations (3)
                        .p = 1, // Threads (1)
                    };

                    const opts = std.crypto.pwhash.argon2.HashOptions{
                        .allocator = ALLOCATOR,
                        .params = params,
                        .encoding = .phc,
                        .mode = .argon2id,
                    };

                    var buf: [120]u8 = undefined;
                    const hash = std.crypto.pwhash.argon2.strHash(
                        register.pwd_text,
                        opts,
                        &buf,
                        state.io,
                    ) catch return error.Unrecoverable;

                    state.db.addUser(register.handle, hash) catch |err| {
                        if (err == error.StepError) {
                            sendUnsecureResp(s_client, parser.ResponseCodes.InvalidCredentials) catch {
                                return error.Unrecoverable;
                            };
                        }

                        return error.NotAuthenticated;
                    };

                    client.status = .Authenticated;
                    // TODO: send SUCCESS response
                    return decrypted_msg;
                },
                .Authenticate => {
                    const decrypted_msg = decrypt(ALLOCATOR, client, msg) catch {
                        sendSecureResp(
                            ALLOCATOR,
                            s_client,
                            client,
                            state.nonce,
                            parser.ResponseCodes.BadMessage,
                        ) catch return error.Unrecoverable;

                        return error.NotAuthenticated;
                    };

                    const authenticate = parser.Authenticate.parse(decrypted_msg) catch {
                        sendSecureResp(
                            ALLOCATOR,
                            s_client,
                            client,
                            state.nonce,
                            parser.ResponseCodes.BadMessage,
                        ) catch return error.Unrecoverable;

                        return error.NotAuthenticated;
                    };

                    const user = state.db.getUser(authenticate.handle) catch {
                        sendSecureResp(
                            ALLOCATOR,
                            s_client,
                            client,
                            state.nonce,
                            parser.ResponseCodes.InvalidCredentials,
                        ) catch return error.Unrecoverable;

                        return error.NotAuthenticated;
                    };

                    // hash passworrd
                    Argon2.strVerify(
                        user.pwd_hash,
                        authenticate.pwd_text,
                        .{ .allocator = ALLOCATOR },
                        state.io,
                    ) catch |err| {
                        if (err == error.AuthenticationFailed) {
                            sendSecureResp(
                                ALLOCATOR,
                                s_client,
                                client,
                                state.nonce,
                                parser.ResponseCodes.InvalidCredentials,
                            ) catch return error.Unrecoverable;

                            return error.NotAuthenticated;
                        } else {
                            // TODO: error happened
                            return error.Unrecoverable;
                        }
                    };

                    client.status = .Authenticated; // TODO: maybe attach user from db to client
                    // TODO: send SUCCESS response
                    return decrypted_msg;
                },
                else => {
                    sendSecureResp(
                        ALLOCATOR,
                        s_client,
                        client,
                        state.nonce,
                        parser.ResponseCodes.NotAuthenticated,
                    ) catch return error.Unrecoverable;

                    return error.NotAuthenticated;
                },
            }
        },
        .Authenticated => {
            const decrypted_msg = decrypt(ALLOCATOR, client, msg) catch {
                sendSecureResp(
                    ALLOCATOR,
                    s_client,
                    client,
                    state.nonce,
                    parser.ResponseCodes.BadMessage,
                ) catch return error.Unrecoverable;

                return error.NotAuthenticated;
            };

            return decrypted_msg;
        },
    }
}

// Encryption and decryption helpers

/// returns a message that is encrypted with nonce & tag prepended, header not included
/// caller is responsible for freeing msg returned
fn encrypt(allocator: Allocator, unencrypted_msg: []const u8, nonce: *u96, key: *[32]u8) ![]u8 {
    var nonce_buf: [12]u8 = undefined;
    std.mem.writeInt(u96, &nonce_buf, nonce.*, .big);

    var encrypted_msg: []u8 = try allocator.alloc(u8, unencrypted_msg.len + 28);
    var tag: [16]u8 = undefined;

    Chacha20.encrypt(encrypted_msg[28..], &tag, unencrypted_msg, &[_]u8{}, nonce_buf, key.*);

    // const tag_num = std.mem.readInt(u128, &tag, .native);
    // std.mem.writeInt(u128, &tag, tag_num, .big);
    const ptr: *u128 = @ptrCast(@alignCast(&tag));
    ptr.* = std.mem.nativeToBig(u128, ptr.*);

    @memcpy(encrypted_msg[0..12], nonce_buf[0..]);
    @memcpy(encrypted_msg[12..28], tag[0..]);

    nonce.* += 1; // HACK: doesn't account for multi-threading
    return encrypted_msg;
}

/// takes a encrypted msg with plaintext header and returns plaintext header and decrypted msg
/// caller is responsible for freeing returned msg
fn decrypt(allocator: Allocator, client: *Client, encrypted_msg: []u8) ![]u8 {
    const decrypted_msg = try allocator.alloc(u8, encrypted_msg.len - 28);

    var nonce: [12]u8 = encrypted_msg[6..18].*;
    var tag: [16]u8 = encrypted_msg[18..34].*;

    const ptr: *u96 = @ptrCast(@alignCast(&nonce));
    ptr.* = std.mem.bigToNative(u96, ptr.*);

    const ptr2: *u128 = @ptrCast(@alignCast(&tag));
    ptr2.* = std.mem.bigToNative(u128, ptr2.*);

    @memcpy(decrypted_msg[0..6], encrypted_msg[0..6]);
    try Chacha20.decrypt(decrypted_msg[6..], encrypted_msg[34..], tag, &[_]u8{}, nonce, client.key[0..32].*);

    return decrypted_msg;
}

// Helpers to send error messages
fn sendUnsecureResp(s_client: *server.Client, err: parser.ResponseCodes) !void {
    const err_num: u16 = @intFromEnum(err);
    var err_buf: [2]u8 = undefined;

    std.mem.writeInt(u16, &err_buf, err_num, .big);

    const msg = [_]u8{ 0x01, 0x00, 0x05 } ++ err_buf;
    try s_client.write(@intFromEnum(parser.Opcodes.Response), msg[0..]);
}

fn sendSecureResp(allocator: Allocator, s_client: *server.Client, client: *Client, nonce: *u96, err: parser.ResponseCodes) !void {
    const err_num: u16 = @intFromEnum(err);
    var err_buf: [2]u8 = undefined;

    std.mem.writeInt(u16, &err_buf, err_num, .big);

    const err_msg = [_]u8{ 0x01, 0x00, 0x05 } ++ err_buf;

    const msg = try encrypt(allocator, err_msg[0..], nonce, client.key[0..32]);

    try s_client.write(@intFromEnum(parser.Opcodes.Response), msg);
}
