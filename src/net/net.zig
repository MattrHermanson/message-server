//! Matt Hermanson - 2026
//! Zig Networking Library sits somewhere between directly using Libc and using std.Io.net

const std = @import("std");
const c = @import("libc");

// TODO: Rethink this interms of heap allocating all of this

// Types
pub const SocketLevel = enum(u32) {
    socket = c.SOL_SOCKET,
};

pub const SocketOption = enum(u32) {
    accept_connection = c.SO_ACCEPTCONN,
    broadcast = c.SO_BROADCAST,
    debug = c.SO_DEBUG,
    dont_route = c.SO_DONTROUTE,
    err = c.SO_ERROR,
    keep_alive = c.SO_KEEPALIVE,
    oob_inline = c.SO_OOBINLINE,
    rcv_buffer = c.SO_RCVBUF,
    rcv_low_watermark = c.SO_RCVLOWAT,
    rcv_timeout = c.SO_RCVTIMEO,
    reuse_address = c.SO_REUSEADDR,
    snd_buffer = c.SO_SNDBUF,
    snd_low_watermark = c.SO_SNDLOWAT,
    snd_timeout = c.SO_SNDTIMEO,
    socket_type = c.SO_TYPE,
};

/// **Type** Supported socket domains
pub const SocketDomain = enum(u32) {
    Ipv4 = c.AF_INET,
    Ipv6 = c.AF_INET6,
};

/// **Type** Supported socket types
pub const SocketType = enum(u32) {
    Stream = c.SOCK_STREAM,
    Datagram = c.SOCK_DGRAM,
};

/// **Type** A Socket
pub const Socket = struct {
    fd: u64,
    address: Address,

    /// Creates an endpoint for communication and returns a *Socket*
    pub fn init(domain: SocketDomain, sock_type: SocketType, protocol: i32, isNonBlocking: bool) !Socket {
        const c_domain: c_int = @intCast(@intFromEnum(domain));
        const c_sock_type: c_int = @intCast(@intFromEnum(sock_type));
        const c_protocol: c_int = @intCast(protocol);

        const c_fd = c.socket(c_domain, c_sock_type, c_protocol);

        if (c_fd == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                c.EACCES => error.AccessDenied,
                c.EAFNOSUPPORT => error.AddressFamilyNotSupported,
                c.EINVAL => error.InvalidArguments,
                c.EMFILE => error.TooManyFiles,
                c.ENFILE => error.OutOfMemory,
                c.EPROTONOSUPPORT => error.ProtocolNotSupported,
                else => error.Unexpected,
            };
        }

        if (isNonBlocking) {
            var flags = c.fcntl(c_fd, c.F_GETFL);
            if (flags == -1) return error.NoBlockError;

            flags |= c.O_NONBLOCK;

            if (c.fcntl(c_fd, c.F_SETFL, flags) == -1) return error.NoBlockError;
        }

        return .{
            .fd = @intCast(c_fd),
            .address = undefined,
        };
    }

    pub fn deinit(self: Socket) void {
        _ = std.c.close(@intCast(self.fd));
    }

    /// Accepts a connection on the provided socket and saves the address
    /// of the new connection to address
    pub fn accept(self: Socket, isNonBlocking: bool) !Socket {
        const c_sockfd: c_int = @intCast(self.fd);

        // create c address struct
        var c_address: c.sockaddr_storage = undefined;
        var c_address_len: u32 = @sizeOf(c.sockaddr_storage);

        const fd = c.accept(c_sockfd, @ptrCast(&c_address), &c_address_len);

        if (fd == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                c.EWOULDBLOCK => error.WouldBlock,
                c.EBADF => error.NotAFileDescriptor,
                c.ECONNABORTED => error.ConnectionAborted,
                c.EFAULT => error.NotWriteableMemory,
                c.EINTR => error.Interrupted,
                c.EINVAL => error.InvalidArguments,
                c.EMFILE => error.TooManyFiles,
                c.ENFILE => error.TooManyFiles,
                c.ENOBUFS => error.OutOfMemory,
                c.ENOMEM => error.OutOfMemory,
                c.ENOTSOCK => error.NotASocket,
                c.EOPNOTSUPP => error.OperationNotSupported,
                c.EPERM => error.FirewallDenied,
                c.EPROTO => error.ProtocolError,
                else => error.Unexpected,
            };
        }

        if (isNonBlocking) {
            var flags = c.fcntl(fd, c.F_GETFL);
            if (flags == -1) return error.NoBlockError;
            flags |= c.O_NONBLOCK;
            if (c.fcntl(fd, c.F_SETFL, flags) == -1) return error.NoBlockError;
        }

        var address: Address = undefined;
        packAddress(&c_address, &address);

        return .{
            .fd = @intCast(fd),
            .address = address,
        };
    }

    /// Binds the provided socket to the provided address
    pub fn bind(self: *Socket, address: Address) !void {
        const c_sockfd: c_int = @intCast(self.fd);

        // create c address struct
        var c_address: c.sockaddr_storage = undefined;
        var c_address_len: u32 = undefined;

        unpackAddress(address, @ptrCast(&c_address), &c_address_len);

        const result = c.bind(c_sockfd, @ptrCast(&c_address), c_address_len);

        if (result == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                c.EACCES => error.AccessDenied,
                c.EADDRINUSE => error.AddressInUse,
                c.EBADF => error.NotAFileDescriptor,
                c.EINVAL => error.InvalidArguments,
                c.ENOTSOCK => error.NotASocket,
                c.EADDRNOTAVAIL => error.AddressNotAvailable,
                else => error.Unexpected,
            };
        }

        self.address = address;
    }

    /// Marks the provided socket as a passive listening socket for connections
    /// to be accepted using *accept()*
    pub fn listen(self: Socket, backlog: i32) !void {
        const c_sockfd: c_int = @intCast(self.fd);
        const c_backlog: c_int = @intCast(backlog);

        const result = c.listen(c_sockfd, c_backlog);

        if (result == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                c.EADDRINUSE => error.AddressInUse,
                c.EBADF => error.NotAFileDescriptor,
                c.ENOTSOCK => error.NotASocket,
                c.EOPNOTSUPP => error.OperationNotSupported,
                else => error.Unexpected,
            };
        }
    }

    pub fn connect(self: Socket, address: Address) !void {
        const c_sockfd: c_int = @intCast(self.fd);

        // create c address struct
        var c_address: c.sockaddr_storage = undefined;
        var c_address_len: u32 = undefined;

        unpackAddress(address, @ptrCast(&c_address), &c_address_len);

        const result = c.connect(c_sockfd, @ptrCast(&c_address), c_address_len);

        if (result == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                c.EACCES => error.AccessError,
                c.EPERM => error.PermissionError,
                c.EADDRINUSE => error.AddressInUse,
                c.EADDRNOTAVAIL => error.AddressNotAvailable,
                c.EAFNOSUPPORT => error.AddressFamilyNotSupported,
                c.EWOULDBLOCK => error.WouldBlock,
                c.EBADF => error.NotAFileDescriptor,
                c.EINTR => error.Interrupted,
                c.EISCONN => error.AlreadyConnected,
                c.ENETUNREACH => error.NetworkUnreachable,
                c.ENOTSOCK => error.NotASocket,
                else => error.Unexpected,
            };
        }
    }

    // TODO: needs to be actually implemented - refer to $man socket 7
    pub fn setsockopt(self: Socket, level: SocketLevel, option_name: SocketOption, option_value: ?*const void, option_len: u32) !u32 {
        const c_sockfd: c_int = @intCast(self.fd);
        const c_level: c_int = @intCast(@intFromEnum(level));
        const c_option_name: c_int = @intCast(@intFromEnum(option_name));
        const c_option_len: u32 = @intCast(option_len);

        const result = c.setsockopt(c_sockfd, c_level, c_option_name, option_value, c_option_len);

        if (result == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                c.EBADF => error.NotAFileDescriptor,
                c.EDOM => error.TimeoutTooBig,
                c.EINVAL => error.InvalidArguments,
                c.EISCONN => error.AlreadyConnected,
                c.ENOPROTOOPT => error.OptionNotSupported,
                c.ENOTSOCK => error.NotASocket,
                c.ENOMEM => error.OutOfMemory,
                c.ENOBUFS => error.InsufficientResources,
                else => error.Unexpected,
            };
        }

        return @intCast(result);
    }
};

/// **Type** Generic Address that holds either *Ip4Address* or *Ip6Address*
pub const Address = union(enum) {
    ip4: Ip4Address,
    ip6: Ip6Address,

    pub fn initIp4WithString(port: u16, address: []const u8) !Address {
        const ip4 = try Ip4Address.initWithString(port, address);
        return .{ .ip4 = ip4 };
    }

    pub fn initIp6WithString(port: u16, address: []const u8) !Address {
        const ip6 = try Ip6Address.initWithString(port, address);
        return .{ .ip6 = ip6 };
    }
};

/// **Type** An Ipv4 address
pub const Ip4Address = struct {
    port: u16,
    addr: u32,

    pub fn init(port: u16, address: u32) Ip4Address {
        var ip4: Ip4Address = undefined;
        ip4.setPort(port);
        ip4.setAddress(address);
        return ip4;
    }

    pub fn initWithString(port: u16, address: []const u8) !Ip4Address {
        var ip4: Ip4Address = undefined;
        ip4.setPort(port);
        try ip4.setAddressWithString(address);
        return ip4;
    }

    /// **DO NOT** set port and addr directly unless converting to network byte-order
    pub fn setPort(self: *Ip4Address, new_port: u16) void {
        self.port = std.mem.nativeToBig(u16, new_port);
    }

    pub fn setAddress(self: *Ip4Address, new_address: u32) void {
        self.addr = std.mem.nativeToBig(u32, new_address);
    }

    pub fn setAddressWithString(self: *Ip4Address, new_address: []const u8) error{ParseError}!void {
        if (new_address.len < 7 or new_address.len > 17) {
            return error.ParseError;
        }

        const result = c.inet_pton(c.AF_INET, new_address.ptr, &self.addr);
        if (result == 0 or result == -1) {
            return error.ParseError;
        }
    }
};

/// **Type** An Ipv6 address
pub const Ip6Address = struct {
    port: u16,
    flow_info: u32,
    addr: u128,
    scope_id: u32,

    pub fn init(port: u16, address: u128) Ip6Address {
        var ip6: Ip6Address = undefined;
        ip6.setPort(port);
        ip6.setAddress(address);
        return ip6;
    }

    pub fn initWithString(port: u16, address: []const u8) !Ip6Address {
        var ip6: Ip6Address = undefined;
        ip6.setPort(port);
        try ip6.setAddressWithString(address);
        return ip6;
    }

    /// **DO NOT** set port and addr directly unless converting to network byte-order
    pub fn setPort(self: *Ip6Address, new_port: u16) void {
        self.port = std.mem.nativeToBig(u16, new_port);
    }

    pub fn setAddress(self: *Ip6Address, new_address: u128) void {
        self.addr = std.mem.nativeToBig(u128, new_address);
    }

    pub fn setAddressWithString(self: *Ip6Address, new_address: []const u8) void {
        if (new_address.len < 3 or new_address.len > 46) {
            return error.ParseError;
        }

        const result = c.inet_pton(c.AF_INET6, new_address.ptr, &self.addr);
        if (result == 0 or result == -1) {
            return error.ParseError;
        }
    }
};

// Internal Util Funtions

/// unpacks an *Address* into a C *sockaddr_storage* struct
/// & sets the length ptr to the length of the specific c address struct
fn unpackAddress(address: Address, storage: *c.sockaddr_storage, length: *u32) void {
    switch (address) {
        .ip4 => {
            const c_address_ip4: *c.sockaddr_in = @ptrCast(@alignCast(storage));
            c_address_ip4.*.sin_family = c.AF_INET;
            c_address_ip4.*.sin_port = address.ip4.port;
            c_address_ip4.*.sin_addr.s_addr = address.ip4.addr;
            length.* = @sizeOf(c.sockaddr_in);
        },
        .ip6 => {
            const c_address_ip6: *c.sockaddr_in6 = @ptrCast(@alignCast(storage));
            c_address_ip6.*.sin6_family = c.AF_INET6;
            c_address_ip6.*.sin6_port = address.ip6.port;
            c_address_ip6.*.sin6_flowinfo = address.ip6.flow_info;
            c_address_ip6.*.sin6_addr = @bitCast(address.ip6.addr);
            c_address_ip6.*.sin6_scope_id = address.ip6.scope_id;
            length.* = @sizeOf(c.sockaddr_in6);
        },
    }
}

/// packs a C *sockaddr_storage* struct into an *Address*
fn packAddress(storage: *c.sockaddr_storage, address: *Address) void {
    switch (storage.ss_family) {
        c.AF_INET => {
            const addr_ip4: *c.sockaddr_in = @ptrCast(@alignCast(storage));
            address.* = .{ .ip4 = .{
                .addr = addr_ip4.sin_addr.s_addr,
                .port = addr_ip4.sin_port,
            } };
        },
        c.AF_INET6 => {
            const addr_ip6: *c.sockaddr_in6 = @ptrCast(@alignCast(storage));
            address.* = .{ .ip6 = .{
                .addr = @bitCast(addr_ip6.sin6_addr),
                .flow_info = addr_ip6.sin6_flowinfo,
                .port = addr_ip6.sin6_port,
                .scope_id = addr_ip6.sin6_scope_id,
            } };
        },
        else => return, // FIX: throw error
    }
}

// TODO: move I/O to another file
pub fn read(fd: u64, buffer: []u8) !usize {
    const bytes_read = c.read(@intCast(fd), buffer.ptr, buffer.len);

    if (bytes_read == -1) {
        const errno = std.c._errno().*;

        return switch (errno) {
            c.EWOULDBLOCK => error.WouldBlock,
            c.EBADF => error.NotAFileDescriptor,
            c.EINTR => error.Interrupted,
            c.EINVAL => error.InvalidArguments,
            c.EIO => error.IoError,
            c.ECONNRESET => error.ConnectionReset,
            else => error.Unexpected,
        };
    }

    return @intCast(bytes_read);
}

// NOTE: can pass a max of 8 buffers
pub fn readv(fd: u64, buffers: [][]u8) !usize {
    const MAX_IOVS = 8;

    if (buffers.len > MAX_IOVS) return error.InvalidArguments;

    var iov: [MAX_IOVS]c.iovec = undefined;

    for (buffers, 0..) |buf, i| {
        iov[i] = c.iovec{
            .iov_base = buf.ptr,
            .iov_len = buf.len,
        };
    }

    const bytes_read = c.readv(
        @intCast(fd),
        &iov,
        @intCast(buffers.len),
    );

    if (bytes_read == -1) {
        const errno = std.c._errno().*;

        return switch (errno) {
            c.EWOULDBLOCK => error.WouldBlock,
            c.EBADF => error.NotAFileDescriptor,
            c.EFAULT => error.OutOfAddressSpace,
            c.EINTR => error.Interrupted,
            c.EINVAL => error.InvalidArguments,
            c.EIO => error.IoError,
            c.EISDIR => error.IsDirectory,
            c.ENOBUFS => error.NoBuffers,
            c.ENOMEM => error.OutOfMemory,
            c.ENXIO => error.DeviceDoesNotExist,
            c.ESTALE => error.StaleFile,
            c.ETIMEDOUT => error.ConnectionTimedOut,
            c.ECONNRESET => error.ConnectionReset,
            else => error.Unexpected,
        };
    }

    return @intCast(bytes_read);
}

pub fn write(fd: u64, buffer: []const u8) !usize {
    const bytes_written = c.write(@intCast(fd), buffer.ptr, buffer.len);

    if (bytes_written == -1) {
        const errno = std.c._errno().*;

        return switch (errno) {
            c.EWOULDBLOCK => error.WouldBlock,
            c.EBADF => error.NotAFileDescriptor,
            c.EINTR => error.Interrupted,
            c.EINVAL => error.InvalidArguments,
            c.EIO => error.IoError,
            c.EDQUOT => error.ExhuastedDataQuota,
            c.EFAULT => error.OutOfAddressSpace,
            c.ECONNRESET => error.SocketNotConnected,
            c.EFBIG => error.FileTooBig,
            c.ENETDOWN => error.NetInterfaceDown,
            c.ENETUNREACH => error.NetworkUnreachable,
            c.ENOSPC => error.OutOfSpace,
            c.EPIPE => error.PipeError,
            else => error.Unexpected,
        };
    }

    return @intCast(bytes_written);
}
