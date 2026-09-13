//! Matt Hermanson - 2026
//! Small Zig thread pool module

const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Semaphore = std.Io.Semaphore;

const Task = struct {
    func: *const fn (data: ?*anyopaque) void,
    data: ?*anyopaque,
    next: ?*Task,
};

pub const Threadpool = struct {
    io: std.Io,
    allocator: Allocator,
    workers: []Thread,
    inbox: ?*Task,
    inbox_tail: ?*Task,
    mx: std.Io.Mutex,
    full: Semaphore,
    running: std.atomic.Value(bool),

    pub fn create(io: std.Io, allocator: Allocator, num_threads: usize) !*Threadpool {
        const pool = try allocator.create(Threadpool);

        pool.* = .{
            .io = io,
            .allocator = allocator,
            .workers = try allocator.alloc(Thread, num_threads),
            .inbox = null,
            .inbox_tail = null,
            .mx = .init,
            .full = .{ .permits = 0 },
            .running = std.atomic.Value(bool).init(true),
        };

        for (pool.workers) |*thrd| {
            thrd.* = try Thread.spawn(.{}, workerFunction, .{pool});
        }

        return pool;
    }

    // NOTE: this will trash all work in-flight, maybe want to throw error for that
    pub fn destroy(self: *Threadpool) void {

        // stop and join workers
        self.running.store(false, .release);

        // post permits to unlock all workers
        for (0..self.workers.len) |_| {
            self.full.post(self.io);
        }

        for (self.workers) |thrd| {
            thrd.join();
        }

        self.allocator.free(self.workers);

        while (self.inbox) |task| {
            self.inbox = task.next;
            self.allocator.destroy(task);
        }

        self.allocator.destroy(self);
    }

    fn workerFunction(self: *Threadpool) void {
        while (self.running.load(.acquire)) {
            self.full.waitUncancelable(self.io);

            self.mx.lockUncancelable(self.io);
            if (self.inbox) |task| {
                defer self.allocator.destroy(task);
                self.inbox = task.next; // remove task from inbox first so no workers do the same thing
                if (self.inbox == null) self.inbox_tail = null;

                task.func(task.data);
            }
            self.mx.unlock(self.io);
        }
    }

    // IDEA: return an id, so you can cancel a Task later -\_0_/-
    pub fn push(self: *Threadpool, func: *const fn (data: ?*anyopaque) void, data: ?*anyopaque) !void {
        const new_task = try self.allocator.create(Task);
        new_task.* = .{
            .func = func,
            .data = data,
            .next = null,
        };

        self.mx.lockUncancelable(self.io);
        if (self.inbox == null) {
            self.inbox = new_task;
            self.inbox_tail = new_task;
        } else {
            if (self.inbox_tail) |tail| {
                tail.next = new_task;
                self.inbox_tail = new_task;
            }
        }
        self.mx.unlock(self.io);

        self.full.post(self.io);
    }
};

// TESTING
const DummyTaskStruct = struct {
    letter: u8,
    i: *u8,
    str: []u8,
};

fn dummyTaskFunc(data: ?*anyopaque) void {
    if (data) |ptr| {
        const strct: *DummyTaskStruct = @ptrCast(@alignCast(ptr));
        const current_i = @atomicRmw(u8, strct.i, .Add, 1, .seq_cst);
        strct.str[current_i] = strct.letter;
    }
}

test "Task Completion & Queue Ordering" {
    const thrd_pool = try Threadpool.create(
        std.testing.io,
        std.testing.allocator,
        1,
    );

    var buffer = [_]u8{ 0, 0, 0, 0 };
    var index: u8 = 0;

    var dummy_a: DummyTaskStruct = .{ .letter = 'a', .i = &index, .str = &buffer };
    var dummy_b: DummyTaskStruct = .{ .letter = 'b', .i = &index, .str = &buffer };
    var dummy_c: DummyTaskStruct = .{ .letter = 'c', .i = &index, .str = &buffer };
    var dummy_d: DummyTaskStruct = .{ .letter = 'd', .i = &index, .str = &buffer };

    try thrd_pool.push(dummyTaskFunc, &dummy_a);
    try thrd_pool.push(dummyTaskFunc, &dummy_b);
    try thrd_pool.push(dummyTaskFunc, &dummy_c);
    try thrd_pool.push(dummyTaskFunc, &dummy_d);

    try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .boot);

    thrd_pool.destroy();

    try std.testing.expectEqualStrings("abcd", &buffer);
}
