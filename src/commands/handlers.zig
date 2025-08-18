const std = @import("std");
const core = @import("core.zig");

pub const HandlerFn = fn (ctx: ?*anyopaque, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool;

pub const Handler = struct {
    ctx: ?*anyopaque,
    call: *const HandlerFn,
};

// Core processing loop: single catch of base error, then try handlers
pub fn process(queue: *core.CommandQueue, handlers: []const Handler) void {
    while (queue.popFront()) |cmd| {
        cmd.call(cmd.ctx, queue) catch |err| {
            for (handlers) |h| {
                if (h.call(h.ctx, err, cmd, queue)) break;
            }
            if (cmd.drop) |d| d(cmd.ctx, queue.allocator);
            continue;
        };
        if (cmd.drop) |d| d(cmd.ctx, queue.allocator);
    }
}

// -------- Helpers to avoid duplication --------
inline fn castLogBuffer(hctx: ?*anyopaque) ?*core.LogBuffer {
    const raw = hctx orelse return null;
    const buf: *core.LogBuffer = @ptrCast(@alignCast(raw));
    return buf;
}

inline fn enqueueLog(q: *core.CommandQueue, buf: *core.LogBuffer, source: core.CommandTag, err: anyerror) bool {
    const lctx = q.allocator.create(core.LogCtx) catch return false;
    lctx.* = .{ .buf = buf, .source = source, .err = err };
    const maker = core.CommandFactory(core.LogCtx, core.execLog);
    const cmd = maker.makeOwned(lctx, .log, false, true);
    q.pushBack(cmd) catch {};
    return true;
}

inline fn enqueueWrapper(
    comptime CtxT: type,
    comptime ExecFn: anytype,
    tag: core.CommandTag,
    stage: u8,
    failed: core.Command,
    q: *core.CommandQueue,
) bool {
    const ctx = q.allocator.create(CtxT) catch return false;
    ctx.* = .{ .inner = failed };
    const maker = core.CommandFactory(CtxT, ExecFn);
    var cmd = maker.makeOwned(ctx, tag, true, false);
    cmd.retry_stage = stage;
    q.pushFront(cmd) catch {};
    return true;
}

// -------- Specific handlers (composable strategies) --------

// Retry on first failure for original commands (not retry/log)
pub fn handlerRetryOnFirstFailure(_: ?*anyopaque, _: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (failed.is_wrapper or failed.is_log) return false;
    return enqueueWrapper(core.RetryOnceCtx, core.execRetryOnce, .retry_once, 1, failed, q);
}

// Log when retry-once fails
pub fn handlerLogAfterRetryOnce(hctx: ?*anyopaque, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (!(failed.is_wrapper and failed.retry_stage == 1)) return false;
    const buf = castLogBuffer(hctx) orelse return false;
    return enqueueLog(q, buf, failed.tag, err);
}

// Second retry when retry-once fails
pub fn handlerRetrySecondTime(_: ?*anyopaque, _: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (!(failed.is_wrapper and failed.retry_stage == 1)) return false;
    return enqueueWrapper(core.RetryTwiceCtx, core.execRetryTwice, .retry_twice, 2, failed, q);
}

// Log when retry-twice fails
pub fn handlerLogAfterSecondRetry(hctx: ?*anyopaque, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (!(failed.is_wrapper and failed.retry_stage == 2)) return false;
    const buf = castLogBuffer(hctx) orelse return false;
    return enqueueLog(q, buf, failed.tag, err);
}

// General-purpose logging handler: enqueue a log command for any failure
// Skips logging for an already-log command to avoid loops.
pub fn handlerLogAlways(hctx: ?*anyopaque, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (failed.is_log) return false;
    const buf = castLogBuffer(hctx) orelse return false;
    return enqueueLog(q, buf, failed.tag, err);
}

// -------- Optional registry (router) for (command, exception) -> handler --------
const RouterEntry = struct { tag: core.CommandTag, err_name: []u8, handler: Handler };

pub const ExceptionRouter = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(RouterEntry),

    pub fn init(allocator: std.mem.Allocator) ExceptionRouter {
        return .{ .allocator = allocator, .items = .{} };
    }
    pub fn deinit(self: *ExceptionRouter) void {
        for (self.items.items) |e| self.allocator.free(e.err_name);
        self.items.deinit(self.allocator);
    }
    pub fn register(self: *ExceptionRouter, tag: core.CommandTag, err_name: []const u8, handler: Handler) !void {
        const dup = try self.allocator.dupe(u8, err_name);
        try self.items.append(self.allocator, .{ .tag = tag, .err_name = dup, .handler = handler });
    }
    pub fn handle(self: *ExceptionRouter, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
        const name = @errorName(err);
        for (self.items.items) |e| {
            if (e.tag == failed.tag and std.mem.eql(u8, e.err_name, name)) {
                return e.handler.call(e.handler.ctx, err, failed, q);
            }
        }
        return false;
    }
};

// Variant of process that uses router first, then falls back to list handlers
pub fn processWithRouter(queue: *core.CommandQueue, router: *ExceptionRouter, handlers: []const Handler) void {
    while (queue.popFront()) |cmd| {
        cmd.call(cmd.ctx, queue) catch |err| {
            const used = router.handle(err, cmd, queue);
            if (!used) {
                for (handlers) |h| {
                    if (h.call(h.ctx, err, cmd, queue)) break;
                }
            }
            if (cmd.drop) |d| d(cmd.ctx, queue.allocator);
            continue;
        };
        if (cmd.drop) |d| d(cmd.ctx, queue.allocator);
    }
}
