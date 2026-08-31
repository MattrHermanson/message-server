const std = @import("std");
const net = @import("net");
const server = @import("server.zig");
const Threadpool = @import("threadpool").Threadpool;

const X25519 = std.crypto.dh.X25519;
const Chacha20 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha512 = std.crypto.kdf.hkdf.HkdfSha256;

// Validate Port Number
fn validate_port(port_str: []const u8) !u16 {

    // parse string to u16
    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        return error.InvalidNumber;
    };

    // validate well-known ports
    if (port < 1024) {
        return error.WellKnownPort;
    }

    return port;
}

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
            error.InvalidNumber => {
                try writer.print("Invalid Port Number\n", .{});
                try writer.flush();
            },
            error.WellKnownPort => {
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

    // var thrd_pool = try Threadpool.create(
    //     io,
    //     std.heap.c_allocator,
    //     try std.Thread.getCpuCount(),
    // );
    // thrd_pool.destroy();

    // TODO: generate salt here and include it in the server's udata
    const keys = X25519.KeyPair.generate(io);
    var salt = [_]u8{ 0x12, 0x34, 0x56, 0x78 };

    var server_state: ServerState = .{
        .keys = keys,
        .salt = salt[0..],
    };

    var sv = try server.Server.init(
        io,
        std.heap.c_allocator,
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

// TODO: make file/enum with opcodes

// setup func level client structs and send server's pub key
fn setup(udata: ?*anyopaque, client: *server.Client) server.HandlerFnError!void {
    client.udata = std.heap.c_allocator.create(Client) catch {
        return error.Unrecoverable;
    };

    if (client.udata) |raw_ptr| {
        const clnt: *Client = @ptrCast(@alignCast(raw_ptr));

        clnt.status = .New;

        // send server's pub key
        if (udata) |raw_udata_ptr| {
            const state: *ServerState = @ptrCast(@alignCast(raw_udata_ptr));

            // send pub key
            client.write(0x1, &state.keys.public_key) catch {
                return;
            };
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

            // don't continue if secure connection not established
            if (!try securityHandler(clnt, state, msg)) return false;

            const decrypted_msg = client.allocator.alloc(u8, msg.len - 34) catch return error.Unrecoverable;

            const tag = msg[18..34];
            const nonce = msg[6..18];

            Chacha20.decrypt(decrypted_msg, msg[34..], tag.*, &[_]u8{}, nonce.*, clnt.key[0..32].*) catch {
                // TODO: send error message
                std.debug.print("decrypt error\n", .{});

                return false;
            };

            std.debug.print("Encrypted msg: {s}\n", .{msg});
            std.debug.print("Decrypted msg: {s}\n", .{decrypted_msg});

            return false;
        } else return error.Unrecoverable;
    } else return error.Unrecoverable;
}

fn securityHandler(client: *Client, state: *ServerState, msg: []u8) server.HandlerFnError!bool {
    switch (client.status) {
        .New => {
            var client_pub_key: [32]u8 = undefined;

            // check opcode
            if (msg[2] == 0x01) {
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
            if (msg[2] == 0x02) {
                // receive user and password
                return true; // TODO: implement passwd handling, this is for testing

            } else {
                // TODO: send Error Not Authenticated
                return false;
            }
        },
        .Authenticated => return true,
    }
}

//fn onComplete(udata: ?*anyopaque, client: *server.Client) server.HandlerFnError!bool {}

// Key Exchange: client & server generate X25519 key pairs. Send their public_key to each other.
// Shared Secret: Both parties run X25519.scalarmult() w/ their secret key and other party's public key.
// Key Derivation: Hash shared secret to produce a secure symmetric key.
// Authenticated Encryption: Use ChaCha20-Poly1305 to encrypt and decrypt data using the derived key.

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
