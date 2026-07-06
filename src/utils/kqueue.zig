//! Matt Hermanson - 2026
//! Kqueue wrapper that manages an internal events buffer

const std = @import("std");

const libc = @cImport({
    @cInclude("sys/event.h");
    @cInclude("errno.h");
});

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
    Add = libc.EV_ADD,
    Enable = libc.EV_ENABLE,
    Disable = libc.EV_DISABLE,
    Dispatch = libc.EV_DISPATCH,
    Delete = libc.EV_DELTE,
    Receipt = libc.EV_RECEIPT,
    Oneshot = libc.EV_ONESHOT,
    Clear = libc.EV_CLEAR,
    EOF = libc.EV_EOF,
    Error = libc.EV_ERROR,
};

pub const Filter = enum(16) {
    Read = libc.EVFILT_READ,
    Write = libc.EVFILT_WRITE,
    Vnode = libc.EVFILT_VNODE,
    Proc = libc.EVFILT_PROC,
    Signal = libc.EVFILT_SIGNAL,
    Timer = libc.EVFILT_TIMER,
    User = libc.EVFILT_USER,
};

pub const InitError = error{
    OutOfMemory,
    TooManyFiles,
    Unexpected,
};

pub const KeventError = error{
    AccessDenied,
    Fault,
    BadFileDescriptor,
    Interrupted,
    InvalidArguments,
    NoEvent,
    OutOfMemory,
    ProcessDoesNotExist,
    Unexpected,
};

pub const KeventResult = struct {
    new_events: []Kevent,
    new_errors: []Kevent,
};

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
        const fd: c_int = libc.kqueue();

        if (fd == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                libc.ENOMEM => InitError.OutOfMemory,
                libc.EMFILE => InitError.TooManyFiles,
                libc.ENFILE => InitError.TooManyFiles,
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

    /// Provide changes to register and/or edit current events
    /// wantEvents[true] to receive a updated events and errors list
    /// wantEvents[false] to not block and return immediately
    pub fn kevent(self: *Kqueue, changes: []const Kevent, wantEvents: bool) KeventError!KeventResult {
        // TODO: implement timeout param

        // disable events fetching
        var events_length = self.events.length;
        if (wantEvents == false) {
            events_length = 0;
        }

        const num_events = libc.kevent(
            self.fd,
            changes.ptr,
            changes.len,
            self.events.ptr,
            events_length,
            null,
        );

        // error map
        if (num_events == -1) {
            const errno = std.c._errno().*;

            return switch (errno) {
                libc.EACCES => KeventError.AccessDenied,
                libc.EFAULT => KeventError.Fault,
                libc.EBADF => KeventError.BadFileDescriptor,
                libc.EINTR => KeventError.Interrupted,
                libc.INVAL => KeventError.InvalidArguments,
                libc.ENOENT => KeventError.NoEvent,
                libc.ENOMEM => KeventError.OutOfMemory,
                libc.ESRCH => KeventError.ProcessDoesNotExist,
                else => KeventError.Unexpected,
            };
        }

        // partition and return event and error slices
        const part = partitionErrors(self.events[0..num_events]);

        return .{
            .new_events = self.events[0..part],
            .new_errors = self.events[part..num_events],
        };
    }

    /// Clean up Kqueue
    pub fn deinit(self: *Kqueue) void {
        libc.close(self.fd);
        self.alloc.free(self.events);
    }
};

// in place partition errors to end of events slice
fn partitionErrors(events: []Kevent) usize {
    var left: usize = 0;
    var right: usize = events.len;

    while (left < right) {
        if ((events[left].flags & libc.EV_ERROR) != 0) {
            right -= 1;
            std.mem.swap(Kevent, &events[left], &events[right]);
        } else {
            left += 1;
        }
    }

    return left;
}
