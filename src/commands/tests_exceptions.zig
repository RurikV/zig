const std = @import("std");
const testing = std.testing;
const t = @import("../utils/tests/helpers.zig");
const core = @import("core.zig");
const handlers = @import("handlers.zig");

const LogBuffer = core.LogBuffer;
const CommandQueue = core.CommandQueue;
const CommandFactory = core.CommandFactory;
const AlwaysFailsCtx = core.AlwaysFailsCtx;
const FlakyCtx = core.FlakyCtx;

const Handler = handlers.Handler;
const process = handlers.process;
const handlerRetryOnFirstFailure = handlers.handlerRetryOnFirstFailure;
const handlerLogAfterRetryOnce = handlers.handlerLogAfterRetryOnce;
const handlerRetrySecondTime = handlers.handlerRetrySecondTime;
const handlerLogAfterSecondRetry = handlers.handlerLogAfterSecondRetry;

// ------------------ Tests for Command/Handlers ------------------

test "Exceptions: LogCommand and Log handler enqueue logging after failure" {
    t.tprint("Exceptions test: log after failure\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf = LogBuffer.init(alloc);
    defer buf.deinit();

    var q = CommandQueue.init(alloc);
    defer q.deinit();

    var af = AlwaysFailsCtx{};
    const make_af = CommandFactory(AlwaysFailsCtx, core.execAlwaysFails);
    try q.pushBack(make_af.make(&af, .always_fails));

    const hs = [_]Handler{
        .{ .ctx = null, .call = handlerRetryOnFirstFailure }, // enqueue retry_once
        .{ .ctx = &buf, .call = handlerLogAfterRetryOnce },
    };

    process(&q, hs[0..]);

    // After processing, at least one log line must exist (AlwaysFails -> retry_once -> fails -> log)
    try testing.expect(buf.lines.items.len >= 1);
}

test "Exceptions: retry-once strategy succeeds without logging" {
    t.tprint("Exceptions test: retry once then success, no log\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf = LogBuffer.init(alloc);
    defer buf.deinit();

    var q = CommandQueue.init(alloc);
    defer q.deinit();

    var flaky = FlakyCtx{ .fail_times = 1 };
    const make_flaky = CommandFactory(FlakyCtx, core.execFlaky);
    try q.pushBack(make_flaky.make(&flaky, .flaky));

    const hs = [_]Handler{
        .{ .ctx = null, .call = handlerRetryOnFirstFailure },
        .{ .ctx = &buf, .call = handlerLogAfterRetryOnce },
    };

    process(&q, hs[0..]);

    try testing.expectEqual(@as(usize, 2), flaky.attempts);
    try testing.expectEqual(@as(usize, 0), buf.lines.items.len);
}

test "Exceptions: first fail -> retry, second fail -> log" {
    t.tprint("Exceptions test: first fail retry, second fail log\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf = LogBuffer.init(alloc);
    defer buf.deinit();

    var q = CommandQueue.init(alloc);
    defer q.deinit();

    var flaky = FlakyCtx{ .fail_times = 2 };
    const make_flaky = CommandFactory(FlakyCtx, core.execFlaky);
    try q.pushBack(make_flaky.make(&flaky, .flaky));

    const hs = [_]Handler{
        .{ .ctx = null, .call = handlerRetryOnFirstFailure },
        .{ .ctx = &buf, .call = handlerLogAfterRetryOnce },
    };

    process(&q, hs[0..]);

    try testing.expectEqual(@as(usize, 2), flaky.attempts);
    try testing.expectEqual(@as(usize, 1), buf.lines.items.len);
}

test "Exceptions: retry twice then log" {
    t.tprint("Exceptions test: retry twice then log\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var buf = LogBuffer.init(alloc);
    defer buf.deinit();

    var q = CommandQueue.init(alloc);
    defer q.deinit();

    var af = AlwaysFailsCtx{};
    const make_af = CommandFactory(AlwaysFailsCtx, core.execAlwaysFails);
    try q.pushBack(make_af.make(&af, .always_fails));

    const hs = [_]Handler{
        .{ .ctx = null, .call = handlerRetryOnFirstFailure },
        .{ .ctx = null, .call = handlerRetrySecondTime },
        .{ .ctx = &buf, .call = handlerLogAfterSecondRetry },
    };

    process(&q, hs[0..]);

    // attempts: original + retry_once + retry_twice = 3
    try testing.expectEqual(@as(usize, 3), af.attempts);
    try testing.expectEqual(@as(usize, 1), buf.lines.items.len);
}
