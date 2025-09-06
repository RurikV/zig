const std = @import("std");
const core = @import("core.zig");

const Allocator = std.mem.Allocator;

pub const Worker = struct {
    allocator: Allocator,

    // Internal queue protected by mtx
    queue: core.CommandQueue,
    mtx: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},

    // Thread/flags
    thread: ?std.Thread = null,
    started: bool = false,
    running: bool = false,
    req_hard_stop: bool = false,
    req_soft_stop: bool = false,

    pub fn init(a: Allocator) Worker {
        return .{ .allocator = a, .queue = core.CommandQueue.init(a) };
    }

    pub fn deinit(self: *Worker) void {
        // Ensure stopped
        _ = self.hardStopJoin() catch {};
        // Drop any pending commands, if any
        while (self.queue.popFront()) |cmd| {
            if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        }
        self.queue.deinit();
    }

    fn loopFn(self: *Worker) void {
        self.mtx.lock();
        self.started = true;
        self.running = true;
        self.cv.broadcast();
        while (true) {
            // Break immediately on hard stop request
            if (self.req_hard_stop) break;
            // Wait for work if empty
            if (self.queue.isEmpty()) {
                if (self.req_soft_stop) break; // stop when empty and soft stop requested
                self.cv.wait(&self.mtx);
                continue;
            }
            // Get work
            const cmd = self.queue.popFront().?;
            // Execute under lock; allow commands to enqueue more work safely
            cmd.call(cmd.ctx, &self.queue) catch {};
            if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        }
        self.running = false;
        self.cv.broadcast();
        self.mtx.unlock();
    }

    pub fn start(self: *Worker) !void {
        self.mtx.lock();
        defer self.mtx.unlock();
        if (self.thread != null and self.running) return error.AlreadyStarted;
        // reset flags
        self.req_hard_stop = false;
        self.req_soft_stop = false;
        self.started = false;
        // spawn thread
        const th = try std.Thread.spawn(.{}, loopEntry, .{self});
        self.thread = th;
    }

    fn loopEntry(self: *Worker) void {
        self.loopFn();
    }

    pub fn waitStarted(self: *Worker) void {
        self.mtx.lock();
        while (!self.started) self.cv.wait(&self.mtx);
        self.mtx.unlock();
    }

    pub fn enqueue(self: *Worker, cmd: core.Command) void {
        self.mtx.lock();
        self.queue.pushBack(cmd) catch {
            self.mtx.unlock();
            return;
        };
        self.cv.broadcast();
        self.mtx.unlock();
    }

    pub fn softStopJoin(self: *Worker) !void {
        var to_join: ?std.Thread = null;
        self.mtx.lock();
        if (self.thread) |th| {
            self.req_soft_stop = true;
            self.cv.broadcast();
            to_join = th;
        }
        self.mtx.unlock();
        if (to_join) |th| th.join();
        self.mtx.lock();
        self.thread = null;
        self.mtx.unlock();
    }

    pub fn hardStopJoin(self: *Worker) !void {
        var to_join: ?std.Thread = null;
        self.mtx.lock();
        if (self.thread) |th| {
            self.req_hard_stop = true;
            self.cv.broadcast();
            to_join = th;
        }
        self.mtx.unlock();
        if (to_join) |th| th.join();
        self.mtx.lock();
        self.thread = null;
        self.mtx.unlock();
    }

    // Testing helpers
    pub fn pendingCount(self: *Worker) usize {
        self.mtx.lock();
        const n = self.queue.list.items.len;
        self.mtx.unlock();
        return n;
    }
};

// ---------------- Commands to control Worker ----------------
pub const StartCtx = struct { worker: *Worker };
pub fn execStart(ctx: *StartCtx, _: *core.CommandQueue) !void {
    try ctx.worker.start();
}

pub const HardStopCtx = struct { worker: *Worker };
pub fn execHardStop(ctx: *HardStopCtx, _: *core.CommandQueue) !void {
    try ctx.worker.hardStopJoin();
}

pub const SoftStopCtx = struct { worker: *Worker };
pub fn execSoftStop(ctx: *SoftStopCtx, _: *core.CommandQueue) !void {
    try ctx.worker.softStopJoin();
}

pub const ThreadingFactory = struct {
    pub fn StartCommand(ctx: *StartCtx) core.Command {
        const Maker = core.CommandFactory(StartCtx, execStart);
        return Maker.make(ctx, .flaky);
    }
    pub fn HardStopCommand(ctx: *HardStopCtx) core.Command {
        const Maker = core.CommandFactory(HardStopCtx, execHardStop);
        return Maker.make(ctx, .flaky);
    }
    pub fn SoftStopCommand(ctx: *SoftStopCtx) core.Command {
        const Maker = core.CommandFactory(SoftStopCtx, execSoftStop);
        return Maker.make(ctx, .flaky);
    }
};
