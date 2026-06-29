const std = @import("std");

const libc = @cImport({
    @cInclude("errno.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
});

// IDEAS:
//  - [ ] socket type that has read only values with the current flags
//  - [ ] address type that w/ len inside, remove len from params
//  - [ ] enums for all options, protocols, etc
//  - [ ] switch pointer/length pairs for byte slices

const c = struct {
    pub extern "c" fn accept(sockfd: c_int, addr: ?*libc.sockaddr, addrlen: ?*libc.socklen_t) c_int;
    pub extern "c" fn bind(sockfd: c_int, addr: ?*const libc.sockaddr, addrlen: libc.socklen_t) c_int;
    pub extern "c" fn listen(sockfd: c_int, backlog: c_int) c_int;
    pub extern "c" fn setsockopt(socket: c_int, level: c_int, option_name: c_int, option_value: ?*const void, option_len: socklen_t) c_int;
    pub extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
};

// Types

/// **Type** A Socket
pub const Socket = struct {
    fd: u32,
};

/// **Type** Generic Address that holds either *Ip4Address* or *Ip6Address*
pub const Address = union(enum) {
    ip4: Ip4Address,
    ip6: Ip6Address,
};

/// **Type** An Ipv4 address
pub const Ip4Address = struct {
    port: u16,
    addr: u32,

    /// **DO NOT** set port and addr directly unless converting to network byte-order
    pub fn setPort(self: Ip4Address, new_port: u16) void {
        self.port = std.mem.nativeToBig(u16, new_port);
    }

    pub fn setAddress(self: Ip4Address, new_address: u32) void {
        self.addr = std.mem.nativeToBig(u32, new_address);
    }
};

/// **Type** An Ipv6 address
pub const Ip6Address = struct {
    port: u16,
    flow_info: u32,
    addr: u128,
    scope_id: u32,

    /// **DO NOT** set port and addr directly unless converting to network byte-order
    pub fn setPort(self: Ip6Address, new_port: u16) void {
        self.port = std.mem.nativeToBig(u16, new_port);
    }

    pub fn setAddress(self: Ip6Address, new_address: u128) void {
        self.addr = std.mem.nativeToBig(u128, new_address);
    }
};

// Internal Util Funtions

/// unpacks an *Address* into a C *sockaddr_storage* struct
/// & sets the length ptr to the length of the specific c address struct
fn unpackAddress(address: Address, storage: *libc.sockaddr_storage, length: *u32) void {
    switch (address) {
        .ip4 => {
            const c_address_ip4: *libc.sockaddr_in = @ptrCast(@alignCast(storage));
            c_address_ip4.*.sin_family = libc.AF_INET;
            c_address_ip4.*.sin_port = address.ip4.port;
            c_address_ip4.*.sin_addr = address.ip4.addr;
            length.* = @sizeOf(libc.sockaddr_in);
        },
        .ip6 => {
            const c_address_ip6: *libc.sockaddr_in6 = @ptrCast(@alignCast(storage));
            c_address_ip6.*.sin6_family = libc.AF_INET6;
            c_address_ip6.*.sin6_port = address.ip6.port;
            c_address_ip6.*.sin6_flowinfo = address.ip6.flow_info;
            c_address_ip6.*.sin6_addr = address.ip6.addr;
            c_address_ip6.*.sin6_addr = address.ip6.addr;
            length.* = @sizeOf(libc.sockaddr_in6);
        },
    }
}

/// packs a C *sockaddr_storage* struct into an *Address*
fn packAddress(storage: *libc.sockaddr_storage, address: *Address) void {
    switch (storage.ss_family) {
        libc.AF_INET => {
            const addr_ip4: *libc.sockaddr_in = @ptrCast(@alignCast(storage));
            address.* = .{ .ip4 = .{
                .addr = addr_ip4.sin_addr,
                .port = addr_ip4.sin_port,
            } };
        },
        libc.AF_INET6 => {
            const addr_ip6: *libc.sockaddr_in6 = @ptrCast(@alignCast(storage));
            address.* = .{ .ip6 = .{
                .addr = addr_ip6.sin6_addr,
                .flow_info = addr_ip6.sin6_flowinfo,
                .port = addr_ip6.sin6_port,
                .scope_id = addr_ip6.sin6_scope_id,
            } };
        },
        else => return, // FIX: throw error
    }
}

// Library Functions

// Accept
pub const AcceptError = error{
    WouldBlock,
    NotAFileDescriptor,
    ConnectionAborted,
    NotWriteableMemory,
    Interrupted,
    InvalidArguments,
    TooManyFiles,
    OutOfMemory,
    NotASocket,
    OperationNotSupported,
    FirewallDenied,
    ProtocolError,
    Unexpected,
};

/// Accepts a connection on the provided socket and saves the address
/// of the new connection to address
pub fn accept(sock: Socket, address: *Address) AcceptError!Socket {
    const c_sockfd: c_int = @intCast(sock.fd);

    // create c address struct
    var c_address: libc.sockaddr_storage = undefined;
    var c_address_len: u32 = @sizeOf(libc.sockaddr_storage);

    const fd = c.accept(c_sockfd, &c_address, &c_address_len);

    if (fd == -1) {
        const errno = std.c._errno().*;

        return switch (errno) {
            libc.EWOULDBLOCK => AcceptError.WouldBlock,
            libc.EAGAIN => AcceptError.WouldBlock,
            libc.EBADF => AcceptError.NotAFileDescriptor,
            libc.ECONNABORTED => AcceptError.ConnectionAborted,
            libc.EFAULT => AcceptError.NotWriteableMemory,
            libc.EINTR => AcceptError.Interrupted,
            libc.EINVAL => AcceptError.InvalidArguments,
            libc.EMFILE => AcceptError.TooManyFiles,
            libc.ENFILE => AcceptError.TooManyFiles,
            libc.ENOBUFS => AcceptError.OutOfMemory,
            libc.ENOMEM => AcceptError.OutOfMemory,
            libc.ENOTSOCK => AcceptError.NotASocket,
            libc.EOPNOTSUPP => AcceptError.OperationNotSupported,
            libc.EPERM => AcceptError.FirewallDenied,
            libc.EPROTO => AcceptError.ProtocolError,
            else => AcceptError.Unexpected,
        };
    }

    packAddress(c_address, address);

    return .{
        .fd = @intCast(fd),
    };
}

// Bind
pub const BindError = error{
    AccessDenied,
    AddressInUse,
    NotAFileDescriptor,
    InvalidArguments,
    NotASocket,
    AddressNotAvailable,
    Unexpected,
};

/// Binds the provided socket to the provided address
pub fn bind(sock: Socket, address: Address) BindError!void {
    const c_sockfd: c_int = @intCast(sock.fd);

    // create c address struct
    var c_address: libc.sockaddr_storage = undefined;
    var c_address_len: u32 = undefined;

    unpackAddress(address, &c_address, &c_address_len);

    const result = c.bind(c_sockfd, c_address, c_address_len);

    if (result == -1) {
        const errno = std.c._errno().*;

        return switch (errno) {
            libc.EACCES => BindError.AccessDenied,
            libc.EADDRINUSE => BindError.AddressInUse,
            libc.EBADF => BindError.NotAFileDescriptor,
            libc.EINVAL => BindError.InvalidArguments,
            libc.ENOTSOCK => BindError.NotASocket,
            libc.EADDRNOTAVAIL => BindError.AddressNotAvailable,
            else => BindError.Unexpected,
        };
    }
}

// Listen
pub const ListenError = error{
    AddressInUse,
    NotAFileDescriptor,
    NotASocket,
    OperationNotSupported,
    Unexpected,
};

/// Marks the provided socket as a passive listening socket for connections
/// to be accepted using *accept()*
pub fn listen(sock: Socket, backlog: i32) ListenError!void {
    const c_sockfd: c_int = @intCast(sock.fd);
    const c_backlog: c_int = @intCast(backlog);

    const result = c.listen(c_sockfd, c_backlog);

    if (result == -1) {
        const errno = std.c._errno().*;

        return switch (errno) {
            libc.EADDRINUSE => ListenError.AddressInUse,
            libc.EBADF => ListenError.NotAFileDescriptor,
            libc.ENOTSOCK => ListenError.NotASocket,
            libc.EOPNOTSUPP => ListenError.OperationNotSupported,
            else => ListenError.Unexpected,
        };
    }
}

// Setsockopt
pub const SetsockoptError = error{
    NotAFileDescriptor,
    TimeoutTooBig,
    InvalidArguments,
    AlreadyConnected,
    OptionNotSupported,
    NotASocket,
    OutOfMemory,
    InsufficientResources,
    Unexpected,
};

pub const SocketLevel = enum(u32) {
    socket = libc.SOL_SOCKET,
};

pub const SocketOption = enum(u32) {
    accept_connection = libc.SO_ACCEPTCONN,
    broadcast = libc.SO_BROADCAST,
    debug = libc.SO_DEBUG,
    dont_route = libc.SO_DONTROUTE,
    err = libc.SO_ERROR,
    keep_alive = libc.SO_KEEPALIVE,
    linger = libc.Linger,
    oob_inline = libc.SO_OOBINLINE,
    rcv_buffer = libc.SO_RCVBUF,
    rcv_low_watermark = libc.SO_RCVLOWAT,
    rcv_timeout = libc.SO_RCVTIMEO,
    reuse_address = libc.SO_REUSEADDR,
    snd_buffer = libc.SO_SNDBUF,
    snd_low_watermark = libc.SO_SNDLOWAT,
    snd_timeout = libc.SO_SNDTIMEO,
    socket_type = libc.SO_TYPE,
};

// TODO: needs to be actually implemented - refer to $man socket 7
pub fn setsockopt(sock: Socket, level: SocketLevel, option_name: SocketOption, option_value: ?*const void, option_len: u32) SetsockoptError!u32 {
    const c_sockfd: c_int = @intCast(sock.fd);
    const c_level: c_int = @intCast(level);
    const c_option_name: c_int = @intCast(option_name);
    const c_option_len: u32 = @intCast(option_len);

    const result = c.setsockopt(c_sockfd, c_level, c_option_name, option_value, c_option_len);

    if (result == -1) {
        const errno = std.c._errno().*;

        return switch (errno) {
            libc.EBADF => SetsockoptError.NotAFileDescriptor,
            libc.EDOM => SetsockoptError.TimeoutTooBig,
            libc.EINVAL => SetsockoptError.InvalidArguments,
            libc.EISCONN => SetsockoptError.AlreadyConnected,
            libc.ENOPROTOOPT => SetsockoptError.OptionNotSupported,
            libc.ENOTSOCK => SetsockoptError.NotASocket,
            libc.ENOMEM => SetsockoptError.OutOfMemory,
            libc.ENOBUFS => SetsockoptError.InsufficientResources,
            else => SetsockoptError.Unexpected,
        };
    }

    return result;
}

// Socket
pub const SocketError = error{
    AccessDenied,
    AddressFamilyNotSupported,
    InvalidArguments,
    TooManyFiles,
    OutOfMemory,
    ProtocolNotSupported,
    Unexpected,
};

/// **Type** Supported socket domains
pub const SocketDomain = enum(u32) {
    Ipv4 = libc.AF_INET,
    Ipv6 = libc.AF_INET6,
};

/// **Type** Supported socket types
pub const SocketType = enum(u32) {
    Stream = libc.SOCK_STREAM,
    Datagram = libc.SOCK_DGRAM,
};

/// Creates an endpoint for communication and returns a *Socket*
pub fn socket(domain: SocketDomain, sock_type: SocketType, protocol: i32) SocketError!Socket {
    const c_domain: c_int = @intCast(@intFromEnum(domain));
    const c_sock_type: c_int = @intCast(@intFromEnum(sock_type));
    const c_protocol: c_int = @intCast(protocol);

    const c_fd = c.socket(c_domain, c_sock_type, c_protocol);

    if (c_fd == -1) {
        const errno = std.c._errno().*;

        return switch (errno) {
            libc.EACCES => SocketError.AccessDenied,
            libc.EAFNOSUPPORT => SocketError.AddressFamilyNotSupported,
            libc.EINVAL => SocketError.InvalidArguments,
            libc.EMFILE => SocketError.TooManyFiles,
            libc.ENFILE => SocketError.OutOfMemory,
            libc.EPROTONOSUPPORT => SocketError.ProtocolNotSupported,
            else => SocketError.Unexpected,
        };
    }

    return .{
        .fd = @intCast(c_fd),
    };
}
