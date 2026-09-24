const std = @import("std");
const Allocator = std.mem.Allocator;
const main = @import("main.zig");
const parser = @import("parser.zig");

const Argon2 = std.crypto.pwhash.argon2;

const MAGIC_BYTE: u8 = 'M';
const VERSION: u8 = 1;

pub const Result = union(enum) {
    response: parser.ResponseCodes,
    loaded_response: ResultMessage,
};

pub const ResultMessage = struct {
    response_code: parser.ResponseCodes,
    payload: []u8,
};

pub fn routeOperation(io: std.Io, allocator: Allocator, client: *main.Client, context: main.AppContext, msg: []u8) !Result {

    // verify header
    if (msg[0] != MAGIC_BYTE) return error.BadMessage;
    if (msg[1] != VERSION) return error.InvalidVersion;

    const opcode = msg[2];

    switch (@as(parser.Opcodes, @enumFromInt(opcode))) {
        .Handshake => {
            unreachable;
        },
        .Register => {
            if (client.status != .Established) return error.InvalidStatus;

            return register(io, allocator, client, context, msg);
        },
        .Authenticate => {
            if (client.status != .Established) return error.InvalidStatus;

            return authenticate(io, allocator, client, context, msg);
        },
        .Response => {
            unreachable;
        },
        .SendMessage => {
            if (client.status != .Authenticated) return error.InvalidStatus;

            return sendMessage(io, allocator, client, context, msg);
        },
        .GetLastMessages => {
            if (client.status != .Authenticated) return error.InvalidStatus;

            return getLastMessages(io, allocator, client, context, msg);
        },
        .GetMessages => {
            if (client.status != .Authenticated) return error.InvalidStatus;

            return getMessages(io, allocator, client, context, msg);
        },
        .SearchHandle => {
            if (client.status != .Authenticated) return error.InvalidStatus;

            return searchHandle(io, allocator, client, context, msg);
        },
    }
}

// Opcode Handlers

fn register(io: std.Io, allocator: Allocator, client: *main.Client, context: main.AppContext, msg: []u8) !Result {
    const processed_msg = parser.Register.parse(msg) catch return error.BadMessage;

    // hash plaintext password
    const params = std.crypto.pwhash.argon2.Params{
        .m = 19456, // Memory cost (16 MiB)
        .t = 2, // Time cost in iterations (3)
        .p = 1, // Threads (1)
    };

    const opts = std.crypto.pwhash.argon2.HashOptions{
        .allocator = allocator,
        .params = params,
        .encoding = .phc,
        .mode = .argon2id,
    };

    var buf: [120]u8 = undefined;
    const hash = std.crypto.pwhash.argon2.strHash(
        processed_msg.pwd_text,
        opts,
        &buf,
        io,
    ) catch return error.Unrecoverable;

    const user = context.db.addUser(allocator, processed_msg.handle, hash) catch |err| {
        if (err == error.StepError) return error.InvalidCredentials;

        return error.Unrecoverable;
    };

    client.status = .Authenticated;
    client.id = user.id;
    client.handle = user.handle;

    allocator.free(user.pwd_hash);

    return .{ .response = .Success };
}

fn authenticate(io: std.Io, allocator: Allocator, client: *main.Client, context: main.AppContext, msg: []u8) !Result {
    const processed_msg = parser.Authenticate.parse(msg) catch return error.BadMessage;

    const user = context.db.getUser(allocator, processed_msg.handle) catch return error.InvalidCredentials;

    // hash passworrd
    Argon2.strVerify(
        user.pwd_hash,
        processed_msg.pwd_text,
        .{ .allocator = allocator },
        io,
    ) catch |err| {
        if (err == error.AuthenticationFailed) {
            return error.InvalidCredentials;
        } else {
            return error.Unrecoverable; // error happened
        }
    };

    client.status = .Authenticated;
    client.id = user.id;
    client.handle = user.handle;

    // free allocated fields in user
    allocator.free(user.pwd_hash);

    return .{ .response = .Success };
}

fn sendMessage(io: std.Io, allocator: Allocator, client: *main.Client, context: main.AppContext, msg: []u8) !Result {
    _ = io;
    _ = allocator;
    _ = client;
    _ = context;
    _ = msg;
    return .{ .response = .Success };
}

fn getLastMessages(io: std.Io, allocator: Allocator, client: *main.Client, context: main.AppContext, msg: []u8) !Result {
    _ = io;
    _ = allocator;
    _ = client;
    _ = context;
    _ = msg;
    return .{ .response = .Success };
}

fn getMessages(io: std.Io, allocator: Allocator, client: *main.Client, context: main.AppContext, msg: []u8) !Result {
    _ = io;
    _ = allocator;
    _ = client;
    _ = context;
    _ = msg;
    return .{ .response = .Success };
}

fn searchHandle(io: std.Io, allocator: Allocator, client: *main.Client, context: main.AppContext, msg: []u8) !Result {
    _ = io;
    _ = allocator;
    _ = client;
    _ = context;
    _ = msg;
    return .{ .response = .Success };
}
