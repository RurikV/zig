// New root.zig implementing SOLID-friendly movement and rotation engines with tests
const std = @import("std");
const testing = std.testing;

fn tprint(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[TEST] " ++ fmt, args);
}

// Basic 2D vector type used for position and velocity
pub const Vec2 = struct {
    x: f64,
    y: f64,

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
};

// Engine responsible for straight uniform motion (no deformation, no acceleration)
// It is decoupled from concrete objects and only relies on the object's interface.
// Expected object interface (duck-typed):
//   getPosition(self: *T) !Vec2
//   getVelocity(self: *T) !Vec2
//   setPosition(self: *T, new_pos: Vec2) !void
pub const Movement = struct {
    pub fn step(obj: anytype) !void {
        const pos = try obj.getPosition();
        const vel = try obj.getVelocity();
        try obj.setPosition(Vec2.add(pos, vel));
    }
};

// Engine responsible for rotation around axis
// Expected object interface (duck-typed):
//   getOrientation(self: *T) !f64
//   getAngularVelocity(self: *T) !f64
//   setOrientation(self: *T, new_angle: f64) !void
pub const Rotation = struct {
    pub fn step(obj: anytype) !void {
        const angle = try obj.getOrientation();
        const omega = try obj.getAngularVelocity();
        try obj.setOrientation(angle + omega);
    }
};

// Example implementations used in tests
pub const GoodShip = struct {
    pos: Vec2,
    vel: Vec2,
    angle: f64,
    ang_vel: f64,

    pub fn getPosition(self: *GoodShip) !Vec2 {
        return self.pos;
    }
    pub fn getVelocity(self: *GoodShip) !Vec2 {
        return self.vel;
    }
    pub fn setPosition(self: *GoodShip, p: Vec2) !void {
        self.pos = p;
    }

    pub fn getOrientation(self: *GoodShip) !f64 {
        return self.angle;
    }
    pub fn getAngularVelocity(self: *GoodShip) !f64 {
        return self.ang_vel;
    }
    pub fn setOrientation(self: *GoodShip, a: f64) !void {
        self.angle = a;
    }
};

pub const NoPositionReader = struct {
    vel: Vec2 = .{ .x = 0, .y = 0 },

    pub fn getPosition(_: *NoPositionReader) !Vec2 {
        return error.UnreadablePosition;
    }
    pub fn getVelocity(self: *NoPositionReader) !Vec2 {
        return self.vel;
    }
    pub fn setPosition(_: *NoPositionReader, _: Vec2) !void {
        // pretend to succeed if called; this should not be reached in the failing case
    }
};

pub const NoVelocityReader = struct {
    pos: Vec2 = .{ .x = 0, .y = 0 },

    pub fn getPosition(self: *NoVelocityReader) !Vec2 {
        return self.pos;
    }
    pub fn getVelocity(_: *NoVelocityReader) !Vec2 {
        return error.UnreadableVelocity;
    }
    pub fn setPosition(_: *NoVelocityReader, _: Vec2) !void {}
};

pub const NoPositionWriter = struct {
    pos: Vec2 = .{ .x = 0, .y = 0 },
    vel: Vec2 = .{ .x = 0, .y = 0 },

    pub fn getPosition(self: *NoPositionWriter) !Vec2 {
        return self.pos;
    }
    pub fn getVelocity(self: *NoPositionWriter) !Vec2 {
        return self.vel;
    }
    pub fn setPosition(_: *NoPositionWriter, _: Vec2) !void {
        return error.UnwritablePosition;
    }
};

pub const NoOrientationReader = struct {
    ang_vel: f64 = 0,

    pub fn getOrientation(_: *NoOrientationReader) !f64 {
        return error.UnreadableOrientation;
    }
    pub fn getAngularVelocity(self: *NoOrientationReader) !f64 {
        return self.ang_vel;
    }
    pub fn setOrientation(_: *NoOrientationReader, _: f64) !void {}
};

pub const NoOrientationWriter = struct {
    angle: f64 = 0,
    ang_vel: f64 = 0,

    pub fn getOrientation(self: *NoOrientationWriter) !f64 {
        return self.angle;
    }
    pub fn getAngularVelocity(self: *NoOrientationWriter) !f64 {
        return self.ang_vel;
    }
    pub fn setOrientation(_: *NoOrientationWriter, _: f64) !void {
        return error.UnwritableOrientation;
    }
};

// ------------------ Tests ------------------

// Movement tests (specified in the assignment)
test "Movement: (12,5) + (-7,3) -> (5,8)" {
    tprint("Starting movement test: initial pos=(12,5), vel=(-7,3)\n", .{});
    var ship = GoodShip{
        .pos = .{ .x = 12, .y = 5 },
        .vel = .{ .x = -7, .y = 3 },
        .angle = 0,
        .ang_vel = 0,
    };

    tprint("Stepping movement...\n", .{});
    try Movement.step(&ship);
    tprint("After step pos=({any},{any})\n", .{ ship.pos.x, ship.pos.y });
    try testing.expectEqual(@as(f64, 5), ship.pos.x);
    try testing.expectEqual(@as(f64, 8), ship.pos.y);
    tprint("OK: movement displacement test passed\n", .{});
}

test "Movement: error when position cannot be read" {
    tprint("Starting movement error test: unreadable position\n", .{});
    var bad = NoPositionReader{ .vel = .{ .x = 1, .y = 1 } };
    try testing.expectError(error.UnreadablePosition, Movement.step(&bad));
    tprint("OK: got expected error UnreadablePosition\n", .{});
}

test "Movement: error when velocity cannot be read" {
    tprint("Starting movement error test: unreadable velocity\n", .{});
    var bad = NoVelocityReader{ .pos = .{ .x = 0, .y = 0 } };
    try testing.expectError(error.UnreadableVelocity, Movement.step(&bad));
    tprint("OK: got expected error UnreadableVelocity\n", .{});
}

test "Movement: error when position cannot be written" {
    tprint("Starting movement error test: unwritable position\n", .{});
    var bad = NoPositionWriter{ .pos = .{ .x = 0, .y = 0 }, .vel = .{ .x = 1, .y = 1 } };
    try testing.expectError(error.UnwritablePosition, Movement.step(&bad));
    tprint("OK: got expected error UnwritablePosition\n", .{});
}

// Rotation tests
test "Rotation: angle increases by angular velocity" {
    tprint("Starting rotation test: angle=30, ang_vel=15\n", .{});
    var ship = GoodShip{
        .pos = .{ .x = 0, .y = 0 },
        .vel = .{ .x = 0, .y = 0 },
        .angle = 30,
        .ang_vel = 15,
    };

    tprint("Stepping rotation...\n", .{});
    try Rotation.step(&ship);
    tprint("After step angle={any}\n", .{ ship.angle });
    try testing.expectEqual(@as(f64, 45), ship.angle);
    tprint("OK: rotation increment test passed\n", .{});
}

test "Rotation: error when orientation cannot be read" {
    tprint("Starting rotation error test: unreadable orientation\n", .{});
    var bad = NoOrientationReader{ .ang_vel = 5 };
    try testing.expectError(error.UnreadableOrientation, Rotation.step(&bad));
    tprint("OK: got expected error UnreadableOrientation\n", .{});
}

test "Rotation: error when orientation cannot be written" {
    tprint("Starting rotation error test: unwritable orientation\n", .{});
    var bad = NoOrientationWriter{ .angle = 0, .ang_vel = 90 };
    try testing.expectError(error.UnwritableOrientation, Rotation.step(&bad));
    tprint("OK: got expected error UnwritableOrientation\n", .{});
}


// ================== Command Queue and Exception Handling Framework ==================

const Allocator = std.mem.Allocator;

pub const CommandError = error{ Boom, FlakyFail };

pub const CommandTag = enum {
    log,
    retry_once,
    retry_twice,
    flaky,
    always_fails,
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

pub const CommandFn = fn (ctx: *anyopaque, q: *CommandQueue) anyerror!void;

pub const Command = struct {
    ctx: *anyopaque,
    call: *const CommandFn,
    tag: CommandTag,
};

fn CommandFactory(comptime T: type, comptime exec: fn (*T, *CommandQueue) anyerror!void) type {
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

fn execLog(ctx: *LogCtx, _: *CommandQueue) !void {
    var tmp_buf: [128]u8 = undefined;
    const w = std.fmt.bufPrint(&tmp_buf, "tag={s} err={s}", .{ @tagName(ctx.source), @errorName(ctx.err) }) catch {
        // Fallback minimal message
        return ctx.buf.addLine("log")
            catch {}; // ignore alloc errors in tests
    };
    _ = ctx.buf.addLine(w) catch {};
}

// -------- Test Commands --------

pub const AlwaysFailsCtx = struct { attempts: usize = 0 };
fn execAlwaysFails(ctx: *AlwaysFailsCtx, _: *CommandQueue) CommandError!void {
    ctx.attempts += 1;
    return CommandError.Boom;
}

pub const FlakyCtx = struct { attempts: usize = 0, fail_times: usize = 1 };
fn execFlaky(ctx: *FlakyCtx, _: *CommandQueue) CommandError!void {
    ctx.attempts += 1;
    if (ctx.attempts <= ctx.fail_times) return CommandError.FlakyFail;
    return;
}

// -------- Retry Wrappers --------

pub const RetryOnceCtx = struct { inner: Command };
fn execRetryOnce(ctx: *RetryOnceCtx, q: *CommandQueue) anyerror!void {
    return ctx.inner.call(ctx.inner.ctx, q);
}

pub const RetryTwiceCtx = struct { inner: Command };
fn execRetryTwice(ctx: *RetryTwiceCtx, q: *CommandQueue) anyerror!void {
    return ctx.inner.call(ctx.inner.ctx, q);
}

// -------- Handlers and Processor --------

pub const HandlerFn = fn (buf: ?*LogBuffer, err: anyerror, failed: Command, q: *CommandQueue) bool;

pub const Handler = struct {
    ctx: ?*LogBuffer,
    call: *const HandlerFn,
};

fn process(queue: *CommandQueue, handlers: []const Handler) void {
    while (queue.popFront()) |cmd| {
        cmd.call(cmd.ctx, queue) catch |err| {
            var handled = false;
            for (handlers) |h| {
                if (h.call(h.ctx, err, cmd, queue)) { handled = true; break; }
            }
            // Free owned contexts for wrapper/log commands even on failure
            switch (cmd.tag) {
                .retry_once => {
                    const p: *RetryOnceCtx = @ptrCast(@alignCast(cmd.ctx));
                    queue.allocator.destroy(p);
                },
                .retry_twice => {
                    const p: *RetryTwiceCtx = @ptrCast(@alignCast(cmd.ctx));
                    queue.allocator.destroy(p);
                },
                .log => {
                    const p: *LogCtx = @ptrCast(@alignCast(cmd.ctx));
                    queue.allocator.destroy(p);
                },
                else => {},
            }
            continue;
        };
        // on success, free owned contexts and continue
        switch (cmd.tag) {
            .retry_once => {
                const p: *RetryOnceCtx = @ptrCast(@alignCast(cmd.ctx));
                queue.allocator.destroy(p);
            },
            .retry_twice => {
                const p: *RetryTwiceCtx = @ptrCast(@alignCast(cmd.ctx));
                queue.allocator.destroy(p);
            },
            .log => {
                const p: *LogCtx = @ptrCast(@alignCast(cmd.ctx));
                queue.allocator.destroy(p);
            },
            else => {},
        }
    }
}

// Specific handlers

// Retry on first failure for original commands (not retry/log)
fn handlerRetryOnFirstFailure(_: ?*LogBuffer, _: anyerror, failed: Command, q: *CommandQueue) bool {
    switch (failed.tag) {
        .retry_once, .retry_twice, .log => return false,
        else => {},
    }
    // Enqueue immediate retry-once for the failed command
    const ctx = q.allocator.create(RetryOnceCtx) catch return false;
    ctx.* = .{ .inner = failed };
    const maker = CommandFactory(RetryOnceCtx, execRetryOnce);
    const cmd = maker.make(ctx, .retry_once);
    q.pushFront(cmd) catch {};
    return true;
}

// Log when retry-once fails
fn handlerLogAfterRetryOnce(hctx: ?*LogBuffer, err: anyerror, failed: Command, q: *CommandQueue) bool {
    if (failed.tag != .retry_once) return false;
    const buf = hctx orelse return false;
    const lctx = q.allocator.create(LogCtx) catch return false;
    lctx.* = .{ .buf = buf, .source = failed.tag, .err = err };
    const maker = CommandFactory(LogCtx, execLog);
    q.pushBack(maker.make(lctx, .log)) catch {};
    return true;
}

// Second retry when retry-once fails
fn handlerRetrySecondTime(_: ?*LogBuffer, _: anyerror, failed: Command, q: *CommandQueue) bool {
    if (failed.tag != .retry_once) return false;
    const ctx = q.allocator.create(RetryTwiceCtx) catch return false;
    ctx.* = .{ .inner = failed };
    const maker = CommandFactory(RetryTwiceCtx, execRetryTwice);
    q.pushFront(maker.make(ctx, .retry_twice)) catch {};
    return true;
}

// Log when retry-twice fails
fn handlerLogAfterSecondRetry(hctx: ?*LogBuffer, err: anyerror, failed: Command, q: *CommandQueue) bool {
    if (failed.tag != .retry_twice) return false;
    const buf = hctx orelse return false;
    const lctx = q.allocator.create(LogCtx) catch return false;
    lctx.* = .{ .buf = buf, .source = failed.tag, .err = err };
    const maker = CommandFactory(LogCtx, execLog);
    q.pushBack(maker.make(lctx, .log)) catch {};
    return true;
}

// ------------------ Tests for Command/Handlers ------------------

test "Exceptions: LogCommand and Log handler enqueue logging after failure" {
    tprint("Exceptions test: log after failure\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf = LogBuffer.init(alloc);
    defer buf.deinit();

    var q = CommandQueue.init(alloc);
    defer q.deinit();

    var af = AlwaysFailsCtx{};
    const make_af = CommandFactory(AlwaysFailsCtx, execAlwaysFails);
    try q.pushBack(make_af.make(&af, .always_fails));

    const handlers = [_]Handler{
        .{ .ctx = null, .call = handlerRetryOnFirstFailure }, // enqueue retry_once
        .{ .ctx = &buf, .call = handlerLogAfterRetryOnce },
    };

    process(&q, handlers[0..]);

    // After processing, at least one log line must exist (AlwaysFails -> retry_once -> fails -> log)
    try testing.expect(buf.lines.items.len >= 1);
}

test "Exceptions: retry-once strategy succeeds without logging" {
    tprint("Exceptions test: retry once then success, no log\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf = LogBuffer.init(alloc);
    defer buf.deinit();

    var q = CommandQueue.init(alloc);
    defer q.deinit();

    var flaky = FlakyCtx{ .fail_times = 1 };
    const make_flaky = CommandFactory(FlakyCtx, execFlaky);
    try q.pushBack(make_flaky.make(&flaky, .flaky));

    const handlers = [_]Handler{
        .{ .ctx = null, .call = handlerRetryOnFirstFailure },
        .{ .ctx = &buf, .call = handlerLogAfterRetryOnce },
    };

    process(&q, handlers[0..]);

    try testing.expectEqual(@as(usize, 2), flaky.attempts);
    try testing.expectEqual(@as(usize, 0), buf.lines.items.len);
}

test "Exceptions: first fail -> retry, second fail -> log" {
    tprint("Exceptions test: first fail retry, second fail log\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf = LogBuffer.init(alloc);
    defer buf.deinit();

    var q = CommandQueue.init(alloc);
    defer q.deinit();

    var flaky = FlakyCtx{ .fail_times = 2 };
    const make_flaky = CommandFactory(FlakyCtx, execFlaky);
    try q.pushBack(make_flaky.make(&flaky, .flaky));

    const handlers = [_]Handler{
        .{ .ctx = null, .call = handlerRetryOnFirstFailure },
        .{ .ctx = &buf, .call = handlerLogAfterRetryOnce },
    };

    process(&q, handlers[0..]);

    try testing.expectEqual(@as(usize, 2), flaky.attempts);
    try testing.expectEqual(@as(usize, 1), buf.lines.items.len);
}

test "Exceptions: retry twice then log" {
    tprint("Exceptions test: retry twice then log\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf = LogBuffer.init(alloc);
    defer buf.deinit();

    var q = CommandQueue.init(alloc);
    defer q.deinit();

    var af = AlwaysFailsCtx{};
    const make_af = CommandFactory(AlwaysFailsCtx, execAlwaysFails);
    try q.pushBack(make_af.make(&af, .always_fails));

    const handlers = [_]Handler{
        .{ .ctx = null, .call = handlerRetryOnFirstFailure },
        .{ .ctx = null, .call = handlerRetrySecondTime },
        .{ .ctx = &buf, .call = handlerLogAfterSecondRetry },
    };

    process(&q, handlers[0..]);

    // attempts: original + retry_once + retry_twice = 3
    try testing.expectEqual(@as(usize, 3), af.attempts);
    try testing.expectEqual(@as(usize, 1), buf.lines.items.len);
}
