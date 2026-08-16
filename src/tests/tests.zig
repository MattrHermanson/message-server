const std = @import("std");

comptime {
    _ = @import("reader.zig");
    _ = @import("writer.zig");
    _ = @import("kqueue.zig");
}
