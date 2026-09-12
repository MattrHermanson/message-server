const std = @import("std");

// NOTE: HEADER: |Magic Byte (1)|Version (1)|Opcode (1)|Message Len (3)| - Message length includes header bytes
//       Message: |Nonce (12)|Tag (16)|Msg... |

// TODO: do length verification via length in header, then subsequent points of reference do bounds checking

pub const Opcodes = enum(u8) {
    Handshake = 0x01,
    Register,
    Authenticate,
    Response,

    pub inline fn check(num: u8, code: Opcodes) bool {
        return num == @intFromEnum(code);
    }
};

pub const ResponseCodes = enum(u8) {
    Success = 0x01,
    BadMessage,
    NotSecure,
    NotAuthenticated,
    InvalidCredentials,
};

pub const Header = packed struct {
    mb: u8,
    version: u8,
    opcode: u8,
    length: u24,

    fn parse(msg: []u8) !Header {
        if (msg.len < 6) return error.BadFormat;
        if (msg[0] != 'M') return error.BadFormat;

        const length = std.mem.readInt(u24, msg[3..6], .big);

        return .{
            .mb = msg[0],
            .version = msg[1],
            .opcode = msg[2],
            .length = length,
        };
    }
};

pub const Handshake = struct {
    header: Header,
    pub_key: []u8,

    pub fn parse(msg: []u8) !Handshake {
        const header = try Header.parse(msg);

        if (header.opcode != @intFromEnum(Opcodes.Handshake)) return error.BadFormat;

        return .{
            .header = header,
            .pub_key = msg[6..],
        };
    }
};

pub const Register = struct {
    header: Header,
    handle: []u8,
    pwd_text: []u8,

    pub fn parse(msg: []u8) !Register {
        const header = try Header.parse(msg);

        if (header.opcode != @intFromEnum(Opcodes.Register)) return error.BadFormat;

        const handle_tag_len = std.mem.readInt(u16, msg[7..9], .big);
        const handle_tag = msg[6 .. handle_tag_len + 6];
        if (handle_tag[0] != 1) return error.BadFormat;

        const pwd_text_tag_len = std.mem.readInt(
            u16,
            msg[6 + handle_tag_len + 1 .. 6 + handle_tag_len + 3][0..2],
            .big,
        );
        const pwd_text_tag = msg[6 + handle_tag_len .. 6 + handle_tag_len + pwd_text_tag_len];

        return .{
            .header = header,
            .handle = handle_tag[3..],
            .pwd_text = pwd_text_tag[3..],
        };
    }
};

pub const Authenticate = struct {
    header: Header,
    handle: []u8,
    pwd_text: []u8,

    pub fn parse(msg: []u8) !Authenticate {
        const header = try Header.parse(msg);

        if (header.opcode != @intFromEnum(Opcodes.Authenticate)) return error.BadFormat;

        const handle_tag_len = std.mem.readInt(u16, msg[7..9], .big);
        const handle_tag = msg[6 .. 6 + handle_tag_len];
        if (handle_tag[0] != 1) return error.BadFormat;

        const pwd_text_tag_len = std.mem.readInt(
            u16,
            msg[6 + handle_tag_len + 1 .. 6 + handle_tag_len + 3][0..2],
            .big,
        );
        const pwd_text_tag = msg[6 + handle_tag_len .. 6 + handle_tag_len + pwd_text_tag_len];

        return .{
            .header = header,
            .handle = handle_tag[3..],
            .pwd_text = pwd_text_tag[3..],
        };
    }
};

pub const Response = struct {
    header: Header,
    code: u16,

    pub fn parse(msg: []u8) !Response {
        const header = try Header.parse(msg);

        if (header.opcode != @intFromEnum(Opcodes.Responce)) return error.BadFormat;

        const code = std.mem.readInt(u16, msg[9..11], .big);

        return .{
            .header = header,
            .code = code,
        };
    }
};
