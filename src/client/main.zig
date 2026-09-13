const std = @import("std");
const net = @import("net");
const Allocator = std.mem.Allocator;
const X25519 = std.crypto.dh.X25519;
const Chacha20 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha512 = std.crypto.kdf.hkdf.HkdfSha256;

const ALLOCATOR = std.heap.c_allocator;

// NOTE: HEADER: |Magic Byte (1)|Version (1)|Opcode (1)|Message Len (3)| - Message length includes header bytes
//       Message: |Nonce (12)|Tag (16)|Msg... |

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var nonce_counter: u96 = 0;

    const sock = try net.Socket.init(net.SocketDomain.Ipv4, net.SocketType.Stream, 0, false);
    const address = try net.Address.initIp4WithString(8080, "127.0.0.1");
    const keys = X25519.KeyPair.generate(io);
    const salt = [_]u8{ 0x12, 0x34, 0x56, 0x78 };

    try startup(ALLOCATOR, &nonce_counter, sock, address, keys, salt[0..]);
}

/// returns a message that is encrypted with nonce & tag prepended
/// caller is responsible for freeing msg returned
fn encrypt(allocator: Allocator, unencrypted_msg: []const u8, nonce: *u96, key: *[32]u8) ![]u8 {
    var nonce_buf: [12]u8 = undefined;
    std.mem.writeInt(u96, &nonce_buf, nonce.*, .big);

    var encrypted_msg: []u8 = try allocator.alloc(u8, unencrypted_msg.len + 28);
    var tag: [16]u8 = undefined;

    Chacha20.encrypt(encrypted_msg[28..], &tag, unencrypted_msg, &[_]u8{}, nonce_buf, key.*);

    const tag_num = std.mem.readInt(u128, &tag, .native);
    std.mem.writeInt(u128, &tag, tag_num, .big);

    @memcpy(encrypted_msg[0..12], nonce_buf[0..]);
    @memcpy(encrypted_msg[12..28], tag[0..]);

    nonce.* += 1;
    return encrypted_msg;
}

/// returns a decrypted msg
/// caller is responsible for freeing returned msg
fn decrypt(allocator: Allocator, key: *[32]u8, encrypted_msg: []u8) ![]u8 {
    const decrypted_msg = try allocator.alloc(u8, encrypted_msg.len - 34);

    const tag: [16]u8 = encrypted_msg[18..34].*;
    const nonce: [12]u8 = encrypted_msg[6..18].*;

    try Chacha20.decrypt(decrypted_msg, encrypted_msg[34..], tag, &[_]u8{}, nonce, key.*);

    return decrypted_msg;
}

fn sendPublicKey(sock: net.Socket, key: []const u8) !void {

    // pub key message
    var msg = [_]u8{0} ** 38;
    msg[0] = 'M';
    msg[1] = 0x01;
    msg[2] = 0x01;
    std.mem.writeInt(u24, msg[3..6], 38, .big);
    @memcpy(msg[6..38], key);

    var bytes_written: usize = 0;
    while (bytes_written < msg.len) {
        bytes_written += try net.write(sock.fd, msg[bytes_written..]);
    }
}

fn computeSharedHash(secret_key: []const u8, public_key: []const u8, salt: []const u8, hash_out: []u8) !void {
    const shared_secret = try X25519.scalarmult(secret_key[0..32].*, public_key[0..32].*);
    const prk = Sha512.extract(salt, &shared_secret);
    Sha512.expand(hash_out, "session", prk);
}

fn register(allocator: Allocator, sock: net.Socket, username: []const u8, pwd_text: []const u8, nonce_counter: *u96, key: *[32]u8) !void {

    // create msg payload
    const payload_length: usize = username.len + pwd_text.len + (2 * 3);
    const payload = try allocator.alloc(u8, payload_length);
    defer allocator.free(payload);

    // add username
    payload[0] = 0x01;
    std.mem.writeInt(u16, payload[1..3], @intCast(username.len + 3), .big);
    @memcpy(payload[3 .. username.len + 3], username);

    // add password
    const tag2_start: usize = username.len + 3;
    payload[tag2_start] = 0x02;
    std.mem.writeInt(u16, payload[tag2_start + 1 .. tag2_start + 3][0..2], @intCast(pwd_text.len + 3), .big);
    @memcpy(payload[tag2_start + 3 .. tag2_start + pwd_text.len + 3], pwd_text);

    const cipher = try encrypt(allocator, payload, nonce_counter, key);
    defer allocator.free(cipher);

    // create header for payload
    var msg: []u8 = try allocator.alloc(u8, cipher.len + 6);
    defer allocator.free(msg);

    msg[0] = 'M';
    msg[1] = 0x01;
    msg[2] = 0x02;
    std.mem.writeInt(u24, msg[3..6], @intCast(cipher.len + 6), .big);

    @memcpy(msg[6..], cipher);

    var bytes_written: usize = 0;
    while (bytes_written < msg.len) {
        bytes_written += try net.write(sock.fd, msg[bytes_written..]);
    }
}

fn authenticate(allocator: Allocator, sock: net.Socket, username: []const u8, pwd_text: []const u8, nonce_counter: *u96, key: *[32]u8) !void {

    // create msg payload
    const payload_length: usize = username.len + pwd_text.len + (2 * 3);
    const payload = try allocator.alloc(u8, payload_length);
    defer allocator.free(payload);

    // add username
    payload[0] = 0x01;
    std.mem.writeInt(u16, payload[1..3], @intCast(username.len + 3), .big);
    @memcpy(payload[3 .. username.len + 3], username);

    // add password
    const tag2_start: usize = username.len + 3;
    payload[tag2_start] = 0x02;
    std.mem.writeInt(u16, payload[tag2_start + 1 .. tag2_start + 3][0..2], @intCast(pwd_text.len + 3), .big);
    @memcpy(payload[tag2_start + 3 .. tag2_start + pwd_text.len + 3], pwd_text);

    const cipher = try encrypt(allocator, payload, nonce_counter, key);
    defer allocator.free(cipher);

    // create header for payload
    var msg: []u8 = try allocator.alloc(u8, cipher.len + 6);
    defer allocator.free(msg);

    msg[0] = 'M';
    msg[1] = 0x01;
    msg[2] = 0x03;
    std.mem.writeInt(u24, msg[3..6], @intCast(cipher.len + 6), .big);

    @memcpy(msg[6..], cipher);

    var bytes_written: usize = 0;
    while (bytes_written < msg.len) {
        bytes_written += try net.write(sock.fd, msg[bytes_written..]);
    }
}

fn startup(allocator: Allocator, nonce_counter: *u96, sock: net.Socket, address: net.Address, keys: X25519.KeyPair, salt: []const u8) !void {

    // setup socket
    try sock.connect(address);
    std.debug.print("connected\n", .{});

    try sendPublicKey(sock, keys.public_key[0..]);
    std.debug.print("sent pub key\n", .{});

    // get server's pub key
    var buf: [1024]u8 = undefined;
    const bytes_read = try net.read(sock.fd, &buf);

    if (bytes_read >= 38 and buf[0] == 0x4D and buf[2] == 0x01) {
        var server_pub_key: [32]u8 = undefined;
        @memcpy(&server_pub_key, buf[6..38]);
        std.debug.print("read server's pub key\n", .{});

        // compute key
        var session_key: [32]u8 = undefined;
        try computeSharedHash(
            keys.secret_key[0..],
            buf[6..38][0..],
            salt,
            session_key[0..],
        );
        std.debug.print("computed shared secret\n", .{});

        const username: []const u8 = "testuser";
        const pwd_text: []const u8 = "testpwd";
        try authenticate(allocator, sock, username, pwd_text, nonce_counter, &session_key);

        // Wait for the server's response before exiting
        var resp_buf: [1024]u8 = undefined;
        const bytes_read2 = try net.read(sock.fd, &resp_buf);
        if (bytes_read2 > 0) {
            std.debug.print("Received server response\n", .{});
        }
        std.debug.print("authenticated\n", .{});
    }
}
