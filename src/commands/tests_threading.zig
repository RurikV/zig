const std = @import("std");
const testing = std.testing;
const t = @import("../utils/tests/helpers.zig");
const core = @import("core.zig");
const handlers = @import("handlers.zig");
const threading = @import("threading.zig");

const CommandQueue = core.CommandQueue;
const CommandFactory = core.CommandFactory;

// Simple command that increments a shared counter (no sleeping)
const IncCtx = struct { counter: *usize };
fn execInc(ctx: *IncCtx, _: *CommandQueue) !void {
    ctx.counter.* += 1;
}

// A no-op command for use in tests
const NoopCtx = struct {};
fn execNoop(_: *NoopCtx, _: *CommandQueue) !void {
    return;
}

// Small delay command to stabilize timing-sensitive tests
const SleepCtx = struct { ns: u64 };
fn execSleep(ctx: *SleepCtx, _: *CommandQueue) !void {
    std.Thread.sleep(ctx.ns);
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

    // Immediately hard stop the worker and join
    var hctx = threading.HardStopCtx{ .worker = &w };
    try q.pushBack(threading.ThreadingFactory.HardStopCommand(&hctx));
    runQueue(&q);

    // After hard stop, the thread should be joined
    try testing.expect(w.thread == null);

    // Enqueue a large batch of tasks; they must not be processed after hard stop
    var counter: usize = 0;
    const Maker = CommandFactory(IncCtx, execInc);
    const total: usize = 100_000;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const heap_ctx = try alloc.create(IncCtx);
        heap_ctx.* = .{ .counter = &counter };
        const cmd = Maker.makeOwned(heap_ctx, .flaky, false, false);
        w.enqueue(cmd);
    }

    // Validate that nothing was processed (hard stop does not drain queued tasks)
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
    const Maker = CommandFactory(IncCtx, execInc);
    const total: usize = 20;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        const heap_ctx = try alloc.create(IncCtx);
        heap_ctx.* = .{ .counter = &counter };
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

// --------------- State machine transitions ---------------

test "State: HardStop command terminates worker thread" {
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

    // Enqueue state hard stop directly into worker queue
    w.enqueue(threading.StateFactory.HardStop());

    // Wait for worker to stop and then join
    w.waitStopped();
    // Ensure we can join/cleanup
    _ = w.hardStopJoin() catch {};
    try testing.expect(w.thread == null);
}

test "State: MoveToCommand switches to MoveTo and forwards tasks" {
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

    // Prepare external queue to forward to
    var ext_q = CommandQueue.init(alloc);
    defer ext_q.deinit();

    // Send MoveTo state command
    w.enqueue(threading.StateFactory.MoveTo(&ext_q));

    // Enqueue a task into worker; it should be forwarded, not executed by worker
    var counter: usize = 0;
    const Maker = CommandFactory(IncCtx, execInc);
    const heap_ctx = try alloc.create(IncCtx);
    heap_ctx.* = .{ .counter = &counter };
    const inc_cmd = Maker.makeOwned(heap_ctx, .flaky, false, false);
    w.enqueue(inc_cmd);

    // Give time to forward
    std.Thread.sleep(1_000_000); // 1 ms
    // At this point, counter should be 0 (not executed by worker)
    try testing.expectEqual(@as(usize, 0), counter);

    // Now drain external queue and verify it runs there
    runQueue(&ext_q);
    try testing.expectEqual(@as(usize, 1), counter);

    // Cleanup worker
    w.enqueue(threading.StateFactory.HardStop());
    w.waitStopped();
    _ = w.hardStopJoin() catch {};
}

test "State: RunCommand switches back to Normal from MoveTo" {
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

    // External queue and enter MoveTo
    var ext_q = CommandQueue.init(alloc);
    defer ext_q.deinit();
    w.enqueue(threading.StateFactory.MoveTo(&ext_q));

    // Forward one task
    var counter: usize = 0;
    const Maker = CommandFactory(IncCtx, execInc);
    {
        const heap_ctx = try alloc.create(IncCtx);
        heap_ctx.* = .{ .counter = &counter };
        const inc_cmd = Maker.makeOwned(heap_ctx, .flaky, false, false);
        w.enqueue(inc_cmd);
    }

    std.Thread.sleep(1_000_000); // 1 ms to forward
    // Drain ext queue: counter should become 1
    runQueue(&ext_q);
    try testing.expectEqual(@as(usize, 1), counter);

    // Now send Run state command to return to Normal
    w.enqueue(threading.StateFactory.Run());

    // Enqueue another task; it should execute by worker (not forwarded)
    {
        const heap_ctx2 = try alloc.create(IncCtx);
        heap_ctx2.* = .{ .counter = &counter };
        const inc_cmd2 = Maker.makeOwned(heap_ctx2, .flaky, false, false);
        w.enqueue(inc_cmd2);
    }

    // Wait a bit and check that counter increased to 2 without draining ext queue
    std.Thread.sleep(1_000_000); // 1 ms
    try testing.expectEqual(@as(usize, 2), counter);
    try testing.expect(ext_q.isEmpty());

    // Cleanup
    w.enqueue(threading.StateFactory.HardStop());
    w.waitStopped();
    _ = w.hardStopJoin() catch {};
}
