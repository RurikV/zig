const std = @import("std");
const testing = std.testing;
const t = @import("../utils/tests/helpers.zig");
const core = @import("core.zig");
const handlers = @import("handlers.zig");
const threading = @import("threading.zig");

const CommandQueue = core.CommandQueue;
const CommandFactory = core.CommandFactory;

// Simple command that sleeps for a short time and increments a shared counter
const SleepIncCtx = struct { counter: *usize, ns: u64 };
fn execSleepInc(ctx: *SleepIncCtx, _: *CommandQueue) !void {
    std.time.sleep(ctx.ns);
    ctx.counter.* += 1;
}

// A no-op command for use in tests
const NoopCtx = struct {};
fn execNoop(_: *NoopCtx, _: *CommandQueue) !void {
    return;
}

// Helper to drain a simple queue of commands by executing them directly (single-threaded)
fn runQueue(q: *CommandQueue) void {
    while (q.popFront()) |cmd| {
        cmd.call(cmd.ctx, q) catch {};
        if (cmd.drop) |d| d(cmd.ctx, q.allocator);
    }
}

test "Threading: start command starts worker" {
    t.tprint("Threading start test\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var w = threading.Worker.init(alloc);
    defer w.deinit();

    var q = CommandQueue.init(alloc);
    defer q.deinit();

    var sctx = threading.StartCtx{ .worker = &w };
    const c = threading.ThreadingFactory.StartCommand(&sctx);
    try q.pushBack(c);

    // Run start command in the main test thread via handlers/process-like loop
    runQueue(&q);

    // Wait until the worker signals it's started
    w.waitStarted();

    // Validate that the thread handle exists (started)
    try testing.expect(w.thread != null);
}

test "Threading: hard stop stops without draining remaining tasks" {
    t.tprint("Threading hard stop test\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var w = threading.Worker.init(alloc);
    defer w.deinit();

    // Start worker via command
    var q = CommandQueue.init(alloc);
    defer q.deinit();
    var sctx = threading.StartCtx{ .worker = &w };
    try q.pushBack(threading.ThreadingFactory.StartCommand(&sctx));
    runQueue(&q);
    w.waitStarted();

    // Enqueue several tasks
    var counter: usize = 0;
    const Maker = CommandFactory(SleepIncCtx, execSleepInc);
    const per_ns: u64 = 2_000_000; // 2 ms
    const total: usize = 10;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const ctx = SleepIncCtx{ .counter = &counter, .ns = per_ns };
        // allocate owned context to avoid stack pointer lifetime issues
        const heap_ctx = try alloc.create(SleepIncCtx);
        heap_ctx.* = ctx;
        const cmd = Maker.makeOwned(heap_ctx, .flaky, false, false);
        w.enqueue(cmd);
    }

    // Issue hard stop via command and wait for join
    var hctx = threading.HardStopCtx{ .worker = &w };
    try q.pushBack(threading.ThreadingFactory.HardStopCommand(&hctx));
    runQueue(&q);

    // After hard stop, the thread should be joined and some tasks likely left unprocessed
    try testing.expect(w.thread == null);
    try testing.expect(counter < total);
}

test "Threading: soft stop waits for all queued tasks to finish" {
    t.tprint("Threading soft stop test\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var w = threading.Worker.init(alloc);
    defer w.deinit();

    // Start worker
    var q = CommandQueue.init(alloc);
    defer q.deinit();
    var sctx = threading.StartCtx{ .worker = &w };
    try q.pushBack(threading.ThreadingFactory.StartCommand(&sctx));
    runQueue(&q);
    w.waitStarted();

    // Enqueue several tasks
    var counter: usize = 0;
    const Maker = CommandFactory(SleepIncCtx, execSleepInc);
    const per_ns: u64 = 1_000_000; // 1 ms
    const total: usize = 8;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const heap_ctx = try alloc.create(SleepIncCtx);
        heap_ctx.* = .{ .counter = &counter, .ns = per_ns };
        const cmd = Maker.makeOwned(heap_ctx, .flaky, false, false);
        w.enqueue(cmd);
    }

    // Issue soft stop and wait (joins internally)
    var ssctx = threading.SoftStopCtx{ .worker = &w };
    try q.pushBack(threading.ThreadingFactory.SoftStopCommand(&ssctx));
    runQueue(&q);

    // After soft stop join, all tasks must be completed
    try testing.expect(w.thread == null);
    try testing.expectEqual(total, counter);
    try testing.expectEqual(@as(usize, 0), w.pendingCount());
}
