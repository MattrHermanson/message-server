const std = @import("std");
const net = @import("net");
const Allocator = std.mem.Allocator;
const server = @import("server.zig");
const parser = @import("parser.zig");
const db = @import("db");
const app = @import("app.zig");
const security = @import("security.zig");

const X25519 = std.crypto.dh.X25519;

const expect = std.testing.expect;

const ALLOCATOR = std.heap.c_allocator;

// TYPES
pub const ServerState = struct {
    io: std.Io,
    appContext: AppContext,
    SecurityContext: SecurityContext,
};

pub const AppContext = struct {
    db: *db.Database,
};

pub const SecurityContext = struct {
    keys: X25519.KeyPair,
    salt: []u8,
    nonce: *u96,
};

pub const Status = enum {
    New,
    Established,
    Authenticated,
};

pub const Client = struct {
    status: Status,
    key: []u8,
    id: u64,
    handle: []const u8,

    pub fn deinit(self: *Client, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.handle);
    }
};

fn validate_port(port_str: []const u8) !u16 {
    const port = try std.fmt.parseInt(u16, port_str, 10);
    if (port < 1024) return error.WellKnownPort;
    return port;
}

// TODO: Implement opcodes in docs 5-9

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

    // TODO: pick better salt
    const keys = X25519.KeyPair.generate(io);
    var salt = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var nonce_counter: u96 = 0;

    var database = try db.Database.init(io, ALLOCATOR, "./store.db", "./src/sql/setup.sql");

    var server_state: ServerState = .{
        .io = io,
        .SecurityContext = .{
            .keys = keys,
            .nonce = &nonce_counter,
            .salt = salt[0..],
        },
        .appContext = .{
            .db = &database,
        },
    };

    var sv = try server.Server.init(
        io,
        ALLOCATOR,
        setup,
        handle,
        onClose,
        .fromSeconds(60),
        &server_state,
    );

    try sv.listen(address);

    sv.run() catch |err| {
        std.debug.print("ERROR: {}\n", .{err});
    };

    return 0;
}

// Server Control Functions

/// setup client state and send server's pub key
fn setup(udata: ?*anyopaque, s_client: *server.Client) server.HandlerFnError!void {
    // TODO: refactor some of this into security
    s_client.udata = s_client.allocator.create(Client) catch return error.Unrecoverable;

    if (s_client.udata) |raw_ptr| {
        if (udata) |raw_udata_ptr| {
            const clnt: *Client = @ptrCast(@alignCast(raw_ptr));
            const state: *ServerState = @ptrCast(@alignCast(raw_udata_ptr));

            clnt.status = .New;

            // send server's pub key
            s_client.write(0x1, &state.SecurityContext.keys.public_key) catch {
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

            // process message through security
            const decrypted_msg = security.processMessage(
                s_client.allocator,
                client,
                state.SecurityContext,
                msg,
            ) catch |err| {
                const res_code: parser.ResponseCodes = switch (err) {
                    error.BadMessage => .BadMessage,
                    error.Unrecoverable => return server.HandlerFnError.Unrecoverable,
                    error.NotSecure => .NotSecure,
                };

                sendUnsecureResp(s_client, res_code) catch {
                    return server.HandlerFnError.Unrecoverable;
                };

                return false;
            };

            // execute op
            const result = app.routeOperation(
                state.io,
                s_client.allocator,
                client,
                state.appContext,
                decrypted_msg,
            ) catch |err| {
                const res_code: parser.ResponseCodes = switch (err) {
                    error.BadMessage, error.InvalidVersion => .BadMessage,
                    error.InvalidStatus => .NotSecure,
                    error.Unrecoverable => return server.HandlerFnError.Unrecoverable,
                    error.InvalidCredentials => .InvalidCredentials,
                };

                sendUnsecureResp(s_client, res_code) catch {
                    return server.HandlerFnError.Unrecoverable;
                };

                return false;
            };

            // send response to client loaded or unloaded
            switch (result) {
                .response => |code| {
                    // send simple response
                    sendSecureResp(
                        s_client,
                        client,
                        state.SecurityContext,
                        code,
                    ) catch return server.HandlerFnError.Unrecoverable;
                },
                .loaded_response => |data| {
                    // send complex response
                    const encrpyted_msg = security.encrypt(
                        s_client.allocator,
                        data.payload,
                        state.SecurityContext,
                        client.key[0..32],
                    ) catch {
                        return server.HandlerFnError.Unrecoverable;
                    };

                    s_client.write(@intFromEnum(data.response_code), encrpyted_msg) catch {
                        return server.HandlerFnError.Unrecoverable;
                    };

                    s_client.allocator.free(data.payload);
                    s_client.allocator.free(encrpyted_msg);
                },
            }

            std.debug.print("Client id: {d}, handle: {s}\n", .{ client.id, client.handle });

            s_client.allocator.free(decrypted_msg);
            s_client.allocator.free(msg);

            return false;
        } else return error.Unrecoverable;
    } else return error.Unrecoverable;
}

fn onClose(udata: ?*anyopaque, s_client: *server.Client) void {
    _ = udata.?;

    if (s_client.udata) |raw_client_ptr| {
        const client: *Client = @ptrCast(@alignCast(raw_client_ptr));

        client.deinit(s_client.allocator);
        s_client.allocator.destroy(client);
    }
}

// Helpers to send error messages
pub fn sendUnsecureResp(s_client: *server.Client, code: parser.ResponseCodes) !void {
    const code_num: u16 = @intFromEnum(code);
    var code_buf: [2]u8 = undefined;

    std.mem.writeInt(u16, &code_buf, code_num, .big);

    const msg = [_]u8{ 0x01, 0x00, 0x05 } ++ code_buf;

    try s_client.write(@intFromEnum(parser.Opcodes.Response), msg[0..]);
}

pub fn sendSecureResp(s_client: *server.Client, client: *Client, context: SecurityContext, code: parser.ResponseCodes) !void {
    const code_num: u16 = @intFromEnum(code);
    var code_buf: [2]u8 = undefined;

    std.mem.writeInt(u16, &code_buf, code_num, .big);

    const err_msg = [_]u8{ 0x01, 0x00, 0x05 } ++ code_buf;

    const msg = try security.encrypt(s_client.allocator, err_msg[0..], context, client.key[0..32]);

    try s_client.write(@intFromEnum(parser.Opcodes.Response), msg);

    s_client.allocator.free(msg);
}
