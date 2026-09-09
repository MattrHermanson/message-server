const std = @import("std");

// NOTE: HEADER: |Magic Byte (1)|Version (1)|Opcode (1)|Message Len (3)| - Message length includes header bytes
//       Message: |Nonce (12)|Tag (16)|Msg... |

// TODO: fix stuff so its includes Nonce and Tag. Update design doc

pub const Opcodes = enum(u8) {
    Handshake = 0x01,
    Register,
    Authenticate,
    ErrorMessage,
};

pub const Errcodes = enum(u8) {
    BadMessage = 0x01,
    NotSecure,
    NotAuthenticated,
    InvalidCredentials,
};

pub const Header = extern struct {
    mb: u8,
    version: u8,
    opcode: u8,
    length: u24,
};

pub const Handshake = extern struct {
    header: Header,
    pub_key: []u8,

    pub fn parse(msg: []u8) !Handshake {
        const header: Header = std.mem.bytesAsValue(Header, msg[0..6]);

        if (header.opcode != @intFromEnum(Opcodes.Handshake)) return error.BadFormat;

        return .{
            .header = header,
            .pub_key = msg[6..],
        };
    }
};

pub const Register = struct {
    header: Header,
    nonce: u96,
    tag: u128,
    handle: []u8,
    pwd_text: []u8,

    pub fn parse(msg: []u8) !Register {
        const header: Header = std.mem.bytesAsValue(Header, msg[0..6]);

        if (header.opcode != @intFromEnum(Opcodes.Register)) return error.BadFormat;

        const nonce = std.mem.readInt(u96, msg[6..18], .big);
        const tag = std.mem.readInt(u128, msg[18..34], .big);

        const handle_tag_len = std.mem.readInt(u16, msg[35..37], .big);
        const handle_tag = msg[34..handle_tag_len];
        if (handle_tag[0] != 1) return error.BadFormat;

        const pwd_text_tag_len = std.mem.readInt(
            u16,
            msg[34 + handle_tag_len + 1 .. 34 + handle_tag_len + 2],
            .big,
        );
        const pwd_text_tag = msg[34 + handle_tag_len .. pwd_text_tag_len];

        return .{
            .header = header,
            .nonce = nonce,
            .tag = tag,
            .handle = handle_tag[3..],
            .pwd_text = pwd_text_tag[3..],
        };
    }
};

pub const Authenticate = struct {
    header: Header,
    nonce: u96,
    tag: u128,
    handle: []u8,
    pwd_text: []u8,

    pub fn parse(msg: []u8) !Authenticate {
        const header: Header = std.mem.bytesAsValue(Header, msg[0..6]);

        if (header.opcode != @intFromEnum(Opcodes.Register)) return error.BadFormat;

        const nonce = std.mem.readInt(u96, msg[6..18], .big);
        const tag = std.mem.readInt(u128, msg[18..34], .big);

        const handle_tag_len = std.mem.readInt(u16, msg[35..37], .big);
        const handle_tag = msg[34..handle_tag_len];
        if (handle_tag[0] != 1) return error.BadFormat;

        const pwd_text_tag_len = std.mem.readInt(
            u16,
            msg[34 + handle_tag_len + 1 .. 34 + handle_tag_len + 2],
            .big,
        );
        const pwd_text_tag = msg[34 + handle_tag_len .. pwd_text_tag_len];

        return .{
            .header = header,
            .nonce = nonce,
            .tag = tag,
            .handle = handle_tag[3..],
            .pwd_text = pwd_text_tag[3..],
        };
    }
};

pub const UnsecureError = struct {
    header: Header,
    err: u8,

    pub fn parse(msg: []u8) !UnsecureError {
        const header: Header = std.mem.bytesAsValue(Header, msg[0..6]);

        if (header.opcode != @intFromEnum(Opcodes.Register)) return error.BadFormat;

        return .{
            .header = header,
            .err = msg[msg.len - 1],
        };
    }
};

pub const SecureError = struct {
    header: Header,
    nonce: u96,
    tag: u128,
    err: u8,

    pub fn parse(msg: []u8) !SecureError {
        const header: Header = std.mem.bytesAsValue(Header, msg[0..6]);

        if (header.opcode != @intFromEnum(Opcodes.Register)) return error.BadFormat;

        const nonce = std.mem.readInt(u96, msg[6..18], .big);
        const tag = std.mem.readInt(u128, msg[18..34], .big);

        return .{
            .header = header,
            .nonce = nonce,
            .tag = tag,
            .err = msg[msg.len - 1],
        };
    }
};
