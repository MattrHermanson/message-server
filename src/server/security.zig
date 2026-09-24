const std = @import("std");
const main = @import("main.zig");
const server = @import("server.zig");
const parser = @import("parser.zig");
const Allocator = std.mem.Allocator;

const X25519 = std.crypto.dh.X25519;
const Chacha20 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha512 = std.crypto.kdf.hkdf.HkdfSha256;

// TODO: finish seperating this from main

/// returns a message that is encrypted with nonce & tag prepended, header not included
/// caller is responsible for freeing msg returned
pub fn encrypt(allocator: Allocator, unencrypted_msg: []const u8, context: main.SecurityContext, key: *[32]u8) ![]u8 {
    // convert nonce to native endian
    var nonce_buf: [12]u8 = undefined;
    std.mem.writeInt(u96, &nonce_buf, context.nonce.*, .big);

    var encrypted_msg: []u8 = try allocator.alloc(u8, unencrypted_msg.len + 28);
    var tag: [16]u8 = undefined;

    Chacha20.encrypt(encrypted_msg[28..], &tag, unencrypted_msg, &[_]u8{}, nonce_buf, key.*);

    // convert tag to native endian
    const ptr: *u128 = @ptrCast(@alignCast(&tag));
    ptr.* = std.mem.nativeToBig(u128, ptr.*);

    @memcpy(encrypted_msg[0..12], nonce_buf[0..]);
    @memcpy(encrypted_msg[12..28], tag[0..]);

    context.nonce.* += 1; // HACK: doesn't account for multi-threading
    return encrypted_msg;
}

/// takes a encrypted msg with plaintext header and returns plaintext header and decrypted msg
/// caller is responsible for freeing returned msg
fn decrypt(allocator: Allocator, client: *main.Client, encrypted_msg: []u8) ![]u8 {
    const decrypted_msg = try allocator.alloc(u8, encrypted_msg.len - 28);

    var nonce: [12]u8 = encrypted_msg[6..18].*;
    var tag: [16]u8 = encrypted_msg[18..34].*;

    // convert nonce to native endian
    const ptr: *u96 = @ptrCast(@alignCast(&nonce));
    ptr.* = std.mem.bigToNative(u96, ptr.*);

    // convert tag to native endian
    const ptr2: *u128 = @ptrCast(@alignCast(&tag));
    ptr2.* = std.mem.bigToNative(u128, ptr2.*);

    @memcpy(decrypted_msg[0..6], encrypted_msg[0..6]);
    try Chacha20.decrypt(decrypted_msg[6..], encrypted_msg[34..], tag, &[_]u8{}, nonce, client.key[0..32].*);

    return decrypted_msg;
}

// Carries out handshake and decrypts message
// Caller is responsible for freeing message
pub fn processMessage(allocator: Allocator, client: *main.Client, context: main.SecurityContext, msg: []u8) ![]u8 {
    switch (client.status) {
        .New => {
            // check opcode
            if (parser.Opcodes.check(msg[2], .Handshake)) {
                const handshake = parser.Handshake.parse(msg) catch {
                    return error.BadMessage;
                };

                // convert to 32 byte array
                var client_pub_key: [32]u8 = undefined;
                @memcpy(&client_pub_key, handshake.pub_key);

                // compute shared secret
                const shared_secret = X25519.scalarmult(context.keys.secret_key, client_pub_key) catch {
                    return error.Unrecoverable;
                };

                // compute key
                const prk = Sha512.extract(context.salt, &shared_secret);
                client.key = allocator.alloc(u8, 32) catch return error.Unrecoverable;
                Sha512.expand(client.key, "session", prk);

                client.status = .Established;
                return error.NotSecure;
            } else {
                return error.NotSecure;
            }
        },
        else => {
            // decrypt and pass message through
            const decrypted_msg = decrypt(allocator, client, msg) catch {
                return error.BadMessage;
            };

            return decrypted_msg;
        },
    }
}
