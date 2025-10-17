const std = @import("std");
const core = @import("core.zig");

const Allocator = std.mem.Allocator;

// ------------ State machine (polymorphic via function pointers) ------------
const State = struct {
    ctx: *anyopaque,
    handle: *const fn (ctx: *anyopaque, w: *Worker, cmd: core.Command) ?State,
};

const NormalStateCtx = struct {};
const MoveToStateCtx = struct { to: ?*core.CommandQueue };

inline fn dropCmd(alloc: Allocator, cmd: core.Command) void {
    if (cmd.drop) |d| d(cmd.ctx, alloc);
}

fn normalHandle(raw: *anyopaque, w: *Worker, cmd: core.Command) ?State {
    _ = raw; // no data needed
    switch (cmd.tag) {
        .state_hard_stop => {
            // Drop the command and terminate the thread
            dropCmd(w.allocator, cmd);
            return null;
        },
        .state_move_to => {
            // Extract target queue pointer from command ctx
            const to_q: *core.CommandQueue = @ptrCast(@alignCast(cmd.ctx));
            w.move_to_ctx.to = to_q;
            dropCmd(w.allocator, cmd);
            return w.asMoveToState();
        },
        .state_run => {
            // Already in normal; just continue
            dropCmd(w.allocator, cmd);
            return w.asNormalState();
        },
        else => {
            // Execute regular command
            cmd.call(cmd.ctx, &w.queue) catch {};
            dropCmd(w.allocator, cmd);
            return w.asNormalState();
        },
    }
}

fn moveToHandle(raw: *anyopaque, w: *Worker, cmd: core.Command) ?State {
    const sctx: *MoveToStateCtx = @ptrCast(@alignCast(raw));
    switch (cmd.tag) {
        .state_hard_stop => {
            dropCmd(w.allocator, cmd);
            return null;
        },
        .state_run => {
            dropCmd(w.allocator, cmd);
            return w.asNormalState();
        },
        .state_move_to => {
            // Update target (generic: use worker's shared move_to_ctx)
            const to_q: *core.CommandQueue = @ptrCast(@alignCast(cmd.ctx));
            w.move_to_ctx.to = to_q;
            dropCmd(w.allocator, cmd);
            return w.asMoveToState();
        },
        else => {
            // Redirect to external queue (best-effort)
            if (sctx.to) |to_q| {
                to_q.pushBack(cmd) catch {
                    // If forwarding fails, drop to avoid leaks
                    dropCmd(w.allocator, cmd);
                };
            } else {
                // No target set; drop silently
                dropCmd(w.allocator, cmd);
            }
            return w.asMoveToState();
        },
    }
}

// Helper constructors for states (no heap allocations)
fn makeState(ctx: *anyopaque, handler: *const fn (*anyopaque, *Worker, core.Command) ?State) State {
    return .{ .ctx = ctx, .handle = handler };
}

fn makeNormalState(ctx: *NormalStateCtx) State {
    return makeState(ctx, normalHandle);
}
fn makeMoveToState(ctx: *MoveToStateCtx) State {
    return makeState(ctx, moveToHandle);
}

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

    // State machine contexts (stored to avoid heap allocations)
    normal_ctx: NormalStateCtx = .{},
    move_to_ctx: MoveToStateCtx = .{ .to = null },

    inline fn asNormalState(self: *Worker) State {
        return makeNormalState(&self.normal_ctx);
    }
    inline fn asMoveToState(self: *Worker) State {
        return makeMoveToState(&self.move_to_ctx);
    }

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
        // Start in Normal state
        var state = self.asNormalState();
        while (true) {
            // Break immediately on hard stop request (external)
            if (self.req_hard_stop) break;
            // Wait for work if empty
            if (self.queue.isEmpty()) {
                if (self.req_soft_stop) break; // stop when empty and soft stop requested
                self.cv.wait(&self.mtx);
                continue;
            }
            // Get work
            const cmd = self.queue.popFront().?;
            // Dispatch via state handler
            const next = state.handle(state.ctx, self, cmd);
            if (next) |s| {
                state = s;
                continue;
            } else {
                // state requested termination
                break;
            }
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

    pub fn waitStopped(self: *Worker) void {
        self.mtx.lock();
        while (self.running) self.cv.wait(&self.mtx);
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

// ---------------- State-switch Commands (processed by Worker's state machine) ----------------
// No-op executor generator to avoid duplicating identical exec functions for control commands
pub fn NoopExec(comptime T: type) fn (*T, *core.CommandQueue) anyerror!void {
    return struct {
        pub fn f(_: *T, _: *core.CommandQueue) anyerror!void {
            return;
        }
    }.f;
}

const StatelessCtx = struct {};
var g_stateless_ctx: StatelessCtx = .{};

pub const StateFactory = struct {
    inline fn assertStateTag(tag: core.CommandTag) void {
        // Ensure only state-control tags are used with this factory
        std.debug.assert(tag == .state_hard_stop or tag == .state_move_to or tag == .state_run);
    }

    pub fn makeStateless(tag: core.CommandTag) core.Command {
        assertStateTag(tag);
        const Maker = core.CommandFactory(StatelessCtx, NoopExec(StatelessCtx));
        return Maker.make(&g_stateless_ctx, tag);
    }

    pub fn makeWithCtx(comptime T: type, ctx: *T, tag: core.CommandTag) core.Command {
        assertStateTag(tag);
        const Maker = core.CommandFactory(T, NoopExec(T));
        return Maker.make(ctx, tag);
    }

    // Backward-compatible convenience wrappers
    pub fn HardStop() core.Command {
        return makeStateless(.state_hard_stop);
    }
    pub fn MoveTo(to: *core.CommandQueue) core.Command {
        return makeWithCtx(core.CommandQueue, to, .state_move_to);
    }
    pub fn Run() core.Command {
        return makeStateless(.state_run);
    }
};
