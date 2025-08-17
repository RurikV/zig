const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CommandError = error{ Boom, FlakyFail };

pub const CommandTag = enum {
    log,
    retry_once,
    retry_twice,
    flaky,
    always_fails,
};

pub const CommandFn = fn (ctx: *anyopaque, q: *CommandQueue) anyerror!void;

pub const Command = struct {
    ctx: *anyopaque,
    call: *const CommandFn,
    tag: CommandTag,
};

pub const CommandQueue = struct {
    allocator: Allocator,
    list: std.ArrayListUnmanaged(Command),

    pub fn init(allocator: Allocator) CommandQueue {
        return .{ .allocator = allocator, .list = .{} };
    }
    pub fn deinit(self: *CommandQueue) void {
        self.list.deinit(self.allocator);
    }
    pub fn pushBack(self: *CommandQueue, cmd: Command) !void {
        try self.list.append(self.allocator, cmd);
    }
    pub fn pushFront(self: *CommandQueue, cmd: Command) !void {
        try self.list.insert(self.allocator, 0, cmd);
    }
    pub fn popFront(self: *CommandQueue) ?Command {
        if (self.list.items.len == 0) return null;
        const cmd = self.list.items[0];
        _ = self.list.orderedRemove(0);
        return cmd;
    }
    pub fn isEmpty(self: *CommandQueue) bool {
        return self.list.items.len == 0;
    }
};

pub fn CommandFactory(comptime T: type, comptime exec: fn (*T, *CommandQueue) anyerror!void) type {
    return struct {
        fn thunk(raw: *anyopaque, q: *CommandQueue) anyerror!void {
            const typed: *T = @ptrCast(@alignCast(raw));
            return exec(typed, q);
        }
        pub fn make(ctx: *T, tag: CommandTag) Command {
            return .{ .ctx = ctx, .call = thunk, .tag = tag };
        }
    };
}

// -------- Log Buffer and LogCommand --------

pub const LogBuffer = struct {
    allocator: Allocator,
    lines: std.ArrayListUnmanaged([]u8),

    pub fn init(allocator: Allocator) LogBuffer {
        return .{ .allocator = allocator, .lines = .{} };
    }
    pub fn deinit(self: *LogBuffer) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
    }
    pub fn addLine(self: *LogBuffer, text: []const u8) !void {
        const dup = try self.allocator.dupe(u8, text);
        try self.lines.append(self.allocator, dup);
    }
};

pub const LogCtx = struct {
    buf: *LogBuffer,
    source: CommandTag,
    err: anyerror,
};

pub fn execLog(ctx: *LogCtx, _: *CommandQueue) !void {
    var tmp_buf: [128]u8 = undefined;
    const w = std.fmt.bufPrint(&tmp_buf, "tag={s} err={s}", .{ @tagName(ctx.source), @errorName(ctx.err) }) catch {
        // Fallback minimal message
        return ctx.buf.addLine("log") catch {}; // ignore alloc errors in tests
    };
    _ = ctx.buf.addLine(w) catch {};
}

// -------- Test Commands --------

pub const AlwaysFailsCtx = struct { attempts: usize = 0 };
pub fn execAlwaysFails(ctx: *AlwaysFailsCtx, _: *CommandQueue) CommandError!void {
    ctx.attempts += 1;
    return CommandError.Boom;
}

pub const FlakyCtx = struct { attempts: usize = 0, fail_times: usize = 1 };
pub fn execFlaky(ctx: *FlakyCtx, _: *CommandQueue) CommandError!void {
    ctx.attempts += 1;
    if (ctx.attempts <= ctx.fail_times) return CommandError.FlakyFail;
    return;
}

// -------- Retry Wrappers --------

pub const RetryOnceCtx = struct { inner: Command };
pub fn execRetryOnce(ctx: *RetryOnceCtx, q: *CommandQueue) anyerror!void {
    return ctx.inner.call(ctx.inner.ctx, q);
}

pub const RetryTwiceCtx = struct { inner: Command };
pub fn execRetryTwice(ctx: *RetryTwiceCtx, q: *CommandQueue) anyerror!void {
    return ctx.inner.call(ctx.inner.ctx, q);
}
