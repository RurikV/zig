const std = @import("std");
const core = @import("core.zig");

pub const HandlerFn = fn (ctx: ?*anyopaque, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool;

pub const Handler = struct {
    ctx: ?*anyopaque,
    call: *const HandlerFn,
};

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

// -------- Helpers to avoid extra code --------
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

// -------- Specific handlers --------

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
