//! Matt Hermanson - 2026
//! Kqueue wrapper that manages an internal events buffer

const std = @import("std");
const c = @import("libc");

// Types
pub const Kevent = extern struct {
    identifier: u64,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: i64,
    udata: ?*anyopaque,
    ext: [4]u64,
};

pub const Flag = enum(u16) {
    Add = c.EV_ADD,
    Enable = c.EV_ENABLE,
    Disable = c.EV_DISABLE,
    Dispatch = c.EV_DISPATCH,
    Delete = c.EV_DELETE,
    Receipt = c.EV_RECEIPT,
    Oneshot = c.EV_ONESHOT,
    Clear = c.EV_CLEAR,
    EOF = c.EV_EOF,
    Error = c.EV_ERROR,
};

pub const Filter = enum(i16) {
    Read = c.EVFILT_READ,
    Write = c.EVFILT_WRITE,
    Vnode = c.EVFILT_VNODE,
    Proc = c.EVFILT_PROC,
    Signal = c.EVFILT_SIGNAL,
    Timer = c.EVFILT_TIMER,
    User = c.EVFILT_USER,
};

pub const InitError = error{
    OutOfMemory,
    TooManyFiles,
    Unexpected,
};

pub const Timespec = extern struct {
    sec: u64,
    nsec: u64,
};

/// Helper functions for checking filters and flags
pub fn checkFlag(event: Kevent, flag: Flag) bool {
    return (event.flags & @intFromEnum(flag)) == @intFromEnum(flag);
}

pub fn checkFilter(event: Kevent, filter: Filter) bool {
    return (event.filter & @intFromEnum(filter)) == @intFromEnum(filter);
}

pub const Kqueue = struct {
    fd: u32,
    alloc: std.mem.Allocator,
    events: []Kevent,

    /// Initialize Kqueue with an event buffer of size 1
    pub fn init(allocator: std.mem.Allocator) InitError!Kqueue {
        initWithSize(allocator, 1);
    }

    /// Initialize Kqueue with an arbitrary event buffer size
    pub fn initWithSize(allocator: std.mem.Allocator, num_events: u32) InitError!Kqueue {
        const fd: c_int = c.kqueue();

        if (fd == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                c.ENOMEM => InitError.OutOfMemory,
                c.EMFILE => InitError.TooManyFiles,
                c.ENFILE => InitError.TooManyFiles,
                else => InitError.Unexpected,
            };
        }

        const ev = allocator.alloc(Kevent, num_events) catch {
            return InitError.OutOfMemory;
        };

        return .{
            .fd = @intCast(fd),
            .alloc = allocator,
            .events = ev,
        };
    }

    /// Clean up Kqueue
    pub fn deinit(self: *Kqueue) void {
        c.close(self.fd);
        self.alloc.free(self.events);
    }

    /// Provide changes to register and/or edit current events
    /// wantEvents[true] to receive a updated events and errors list
    /// wantEvents[false] to not block and return immediately
    pub fn kevent(self: *Kqueue, changes: []const Kevent, wantEvents: bool, timeout: ?*Timespec) ![]Kevent {

        // disable events fetching
        var events_length = self.events.len;
        if (wantEvents == false) {
            events_length = 0;
        }

        const num_events: usize = @intCast(c.kevent(
            @intCast(self.fd),
            @ptrCast(changes.ptr),
            @intCast(changes.len),
            @ptrCast(self.events.ptr),
            @intCast(events_length),
            @ptrCast(timeout),
        ));

        // error map
        if (num_events == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                c.EACCES => error.AccessDenied,
                c.EFAULT => error.Fault,
                c.EBADF => error.BadFileDescriptor,
                c.EINTR => error.Interrupted,
                c.EINVAL => error.InvalidArguments,
                c.ENOENT => error.NoEvent,
                c.ENOMEM => error.OutOfMemory,
                c.ESRCH => error.ProcessDoesNotExist,
                else => error.Unexpected,
            };
        }

        return self.events[0..num_events];
    }
};
