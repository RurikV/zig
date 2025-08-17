const std = @import("std");
const core = @import("core.zig");

pub const HandlerFn = fn (buf: ?*core.LogBuffer, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool;

pub const Handler = struct {
    ctx: ?*core.LogBuffer,
    call: *const HandlerFn,
};

pub fn process(queue: *core.CommandQueue, handlers: []const Handler) void {
    while (queue.popFront()) |cmd| {
        cmd.call(cmd.ctx, queue) catch |err| {
            for (handlers) |h| {
                if (h.call(h.ctx, err, cmd, queue)) break;
            }
            // Free owned contexts for wrapper/log commands even on failure
            switch (cmd.tag) {
                .retry_once => {
                    const p: *core.RetryOnceCtx = @ptrCast(@alignCast(cmd.ctx));
                    queue.allocator.destroy(p);
                },
                .retry_twice => {
                    const p: *core.RetryTwiceCtx = @ptrCast(@alignCast(cmd.ctx));
                    queue.allocator.destroy(p);
                },
                .log => {
                    const p: *core.LogCtx = @ptrCast(@alignCast(cmd.ctx));
                    queue.allocator.destroy(p);
                },
                else => {},
            }
            continue;
        };
        // on success, free owned contexts and continue
        switch (cmd.tag) {
            .retry_once => {
                const p: *core.RetryOnceCtx = @ptrCast(@alignCast(cmd.ctx));
                queue.allocator.destroy(p);
            },
            .retry_twice => {
                const p: *core.RetryTwiceCtx = @ptrCast(@alignCast(cmd.ctx));
                queue.allocator.destroy(p);
            },
            .log => {
                const p: *core.LogCtx = @ptrCast(@alignCast(cmd.ctx));
                queue.allocator.destroy(p);
            },
            else => {},
        }
    }
}

// Specific handlers

// Retry on first failure for original commands (not retry/log)
pub fn handlerRetryOnFirstFailure(_: ?*core.LogBuffer, _: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    switch (failed.tag) {
        .retry_once, .retry_twice, .log => return false,
        else => {},
    }
    // Enqueue immediate retry-once for the failed command
    const ctx = q.allocator.create(core.RetryOnceCtx) catch return false;
    ctx.* = .{ .inner = failed };
    const maker = core.CommandFactory(core.RetryOnceCtx, core.execRetryOnce);
    const cmd = maker.make(ctx, .retry_once);
    q.pushFront(cmd) catch {};
    return true;
}

// Log when retry-once fails
pub fn handlerLogAfterRetryOnce(hctx: ?*core.LogBuffer, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (failed.tag != .retry_once) return false;
    const buf = hctx orelse return false;
    const lctx = q.allocator.create(core.LogCtx) catch return false;
    lctx.* = .{ .buf = buf, .source = failed.tag, .err = err };
    const maker = core.CommandFactory(core.LogCtx, core.execLog);
    q.pushBack(maker.make(lctx, .log)) catch {};
    return true;
}

// Second retry when retry-once fails
pub fn handlerRetrySecondTime(_: ?*core.LogBuffer, _: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (failed.tag != .retry_once) return false;
    const ctx = q.allocator.create(core.RetryTwiceCtx) catch return false;
    ctx.* = .{ .inner = failed };
    const maker = core.CommandFactory(core.RetryTwiceCtx, core.execRetryTwice);
    q.pushFront(maker.make(ctx, .retry_twice)) catch {};
    return true;
}

// Log when retry-twice fails
pub fn handlerLogAfterSecondRetry(hctx: ?*core.LogBuffer, err: anyerror, failed: core.Command, q: *core.CommandQueue) bool {
    if (failed.tag != .retry_twice) return false;
    const buf = hctx orelse return false;
    const lctx = q.allocator.create(core.LogCtx) catch return false;
    lctx.* = .{ .buf = buf, .source = failed.tag, .err = err };
    const maker = core.CommandFactory(core.LogCtx, core.execLog);
    q.pushBack(maker.make(lctx, .log)) catch {};
    return true;
}
