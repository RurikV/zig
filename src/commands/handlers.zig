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

// Specific handlers

// Retry on first failure for original commands (not retry/log)
pub fn handlerRetryOnFirstFailure(_: ?*anyopaque, _: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (failed.is_wrapper or failed.is_log) return false;
    // Enqueue immediate retry-once for the failed command
    const ctx = q.allocator.create(core.RetryOnceCtx) catch return false;
    ctx.* = .{ .inner = failed };
    const maker = core.CommandFactory(core.RetryOnceCtx, core.execRetryOnce);
    var cmd = maker.makeOwned(ctx, .retry_once, true, false);
    cmd.retry_stage = 1;
    q.pushFront(cmd) catch {};
    return true;
}

// Log when retry-once fails
pub fn handlerLogAfterRetryOnce(hctx: ?*anyopaque, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (!(failed.is_wrapper and failed.retry_stage == 1)) return false;
    const raw = hctx orelse return false;
    const buf: *core.LogBuffer = @ptrCast(@alignCast(raw));
    const lctx = q.allocator.create(core.LogCtx) catch return false;
    lctx.* = .{ .buf = buf, .source = failed.tag, .err = err };
    const maker = core.CommandFactory(core.LogCtx, core.execLog);
    const cmd = maker.makeOwned(lctx, .log, false, true);
    q.pushBack(cmd) catch {};
    return true;
}

// Second retry when retry-once fails
pub fn handlerRetrySecondTime(_: ?*anyopaque, _: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (!(failed.is_wrapper and failed.retry_stage == 1)) return false;
    const ctx = q.allocator.create(core.RetryTwiceCtx) catch return false;
    ctx.* = .{ .inner = failed };
    const maker = core.CommandFactory(core.RetryTwiceCtx, core.execRetryTwice);
    var cmd = maker.makeOwned(ctx, .retry_twice, true, false);
    cmd.retry_stage = 2;
    q.pushFront(cmd) catch {};
    return true;
}

// Log when retry-twice fails
pub fn handlerLogAfterSecondRetry(hctx: ?*anyopaque, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (!(failed.is_wrapper and failed.retry_stage == 2)) return false;
    const raw = hctx orelse return false;
    const buf: *core.LogBuffer = @ptrCast(@alignCast(raw));
    const lctx = q.allocator.create(core.LogCtx) catch return false;
    lctx.* = .{ .buf = buf, .source = failed.tag, .err = err };
    const maker = core.CommandFactory(core.LogCtx, core.execLog);
    const cmd = maker.makeOwned(lctx, .log, false, true);
    q.pushBack(cmd) catch {};
    return true;
}

// General-purpose logging handler: enqueue a log command for any failure
// Skips logging for an already-log command to avoid loops.
pub fn handlerLogAlways(hctx: ?*anyopaque, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (failed.is_log) return false;
    const raw = hctx orelse return false;
    const buf: *core.LogBuffer = @ptrCast(@alignCast(raw));
    const lctx = q.allocator.create(core.LogCtx) catch return false;
    lctx.* = .{ .buf = buf, .source = failed.tag, .err = err };
    const maker = core.CommandFactory(core.LogCtx, core.execLog);
    const cmd = maker.makeOwned(lctx, .log, false, true);
    q.pushBack(cmd) catch {};
    return true;
}
