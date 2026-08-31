const std = @import("std");
const net = @import("net");
const X25519 = std.crypto.dh.X25519;
const Chacha20 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Sha512 = std.crypto.kdf.hkdf.HkdfSha256;

// NOTE: HEADER: |Magic Byte (1)|Version (1)|Opcode (1)|Message Len (3)| - Message length includes header bytes
//       Message: |Nonce (12)|Tag (16)|Msg... |

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var nonce_counter: u64 = 1;

    // setup socket
    const sock = try net.Socket.init(net.SocketDomain.Ipv4, net.SocketType.Stream, 0, false);
    const address = try net.Address.initIp4WithString(8080, "127.0.0.1");
    try sock.connect(address);

    const keys = X25519.KeyPair.generate(io);
    const salt = [_]u8{ 0x12, 0x34, 0x56, 0x78 };

    // pub key message
    var msg = [_]u8{0} ** 38;
    msg[0] = 0x4D;
    msg[1] = 0x01;
    msg[2] = 0x01;
    std.mem.writeInt(u24, msg[3..6], 38, .big);
    @memcpy(msg[6..38], &keys.public_key);

    const con_msg = msg;

    _ = try net.write(sock.fd, &con_msg);

    // get server's pub key
    var buf: [1024]u8 = undefined;
    const bytes_read = try net.read(sock.fd, &buf);

    if (bytes_read >= 38 and buf[0] == 0x4D and buf[2] == 0x01) {
        var server_pub_key: [32]u8 = undefined;
        @memcpy(&server_pub_key, buf[6..38]);

        const shared_secret = try X25519.scalarmult(keys.secret_key, server_pub_key);

        // compute key
        const prk = Sha512.extract(&salt, &shared_secret);
        var session_key: [32]u8 = undefined;
        Sha512.expand(&session_key, "session", prk);

        const test_string = "Hi from client secretly\n";

        // encrypt test message
        var cipher_text: [test_string.len]u8 = undefined;
        var tag: [16]u8 = undefined;
        var npub = [_]u8{0} ** 12;
        std.mem.writeInt(u64, npub[4..12], nonce_counter, .big);

        Chacha20.encrypt(&cipher_text, &tag, test_string, &[_]u8{}, npub, session_key);

        // Transmit encrypted payload
        // Total len: 6 (header) + 12 (nonce) + 16 (tag) + 24 (ciphertext) = 58
        var msg_2: [58]u8 = undefined;
        msg_2[0] = 0x4D;
        msg_2[1] = 0x01;
        msg_2[2] = 0x02;
        std.mem.writeInt(u24, msg_2[3..6], 58, .big);

        @memcpy(msg_2[6..18], &npub);
        @memcpy(msg_2[18..34], &tag);
        @memcpy(msg_2[34..58], &cipher_text);

        _ = try net.write(sock.fd, &msg_2);
        nonce_counter += 1;
    }
}
