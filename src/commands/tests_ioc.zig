const std = @import("std");
const testing = std.testing;
const t = @import("../utils/tests/helpers.zig");
const vec = @import("../space/vector.zig");
const movement = @import("../space/movement.zig");
const fixtures = @import("../space/fixtures.zig");
const core = @import("core.zig");
const IoC = @import("ioc.zig");

const Movement = movement.Movement;

const TaskCtx = struct { scope: []const u8, factory: *const IoC.FactoryFn, ship: *fixtures.GoodShip, key_name: []const u8 };
fn threadMain(ctx: *TaskCtx) void {
    var gpa_local = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_local.deinit();
    const AA = gpa_local.allocator();
    var q_local = core.CommandQueue.init(AA);
    defer q_local.deinit();
    const set = IoC.Resolve(AA, "Scopes.Current", @ptrCast(@constCast(&ctx.scope)), null) catch unreachable;
    set.call(set.ctx, &q_local) catch unreachable;
    if (set.drop) |d| d(set.ctx, AA);
    const reg = IoC.Resolve(AA, "IoC.Register", @ptrCast(@constCast(&ctx.key_name)), @ptrCast(@constCast(&ctx.factory))) catch unreachable;
    reg.call(reg.ctx, &q_local) catch unreachable;
    if (reg.drop) |d| d(reg.ctx, AA);
    const c = IoC.Resolve(AA, ctx.key_name, ctx.ship, null) catch unreachable;
    c.call(c.ctx, &q_local) catch unreachable;
    if (c.drop) |d| d(c.ctx, AA);
}

// ---- tiny exec wrappers for commands created by factories ----
const MoveCtx = struct { obj: *fixtures.GoodShip };
fn execMove(ctx: *MoveCtx, _: *core.CommandQueue) !void {
    try Movement.step(ctx.obj);
}

const MoveTwiceCtx = struct { obj: *fixtures.GoodShip };
fn execMoveTwice(ctx: *MoveTwiceCtx, _: *core.CommandQueue) !void {
    try Movement.step(ctx.obj);
    try Movement.step(ctx.obj);
}

// ---- Factories ----
fn factory_make_move(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const pobj: *fixtures.GoodShip = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const mctx = try allocator.create(MoveCtx);
    mctx.* = .{ .obj = pobj };
    const Maker = core.CommandFactory(MoveCtx, execMove);
    return Maker.makeOwned(mctx, .flaky, false, false);
}

fn factory_make_move_twice(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const pobj: *fixtures.GoodShip = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const mctx = try allocator.create(MoveTwiceCtx);
    mctx.* = .{ .obj = pobj };
    const Maker = core.CommandFactory(MoveTwiceCtx, execMoveTwice);
    return Maker.makeOwned(mctx, .flaky, false, false);
}

// ------------- Tests -------------

// 1) Registration and simple resolve: move once
test "IoC: register and resolve move command in default scope" {
    t.tprint("IoC test: register/resolve in root scope\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    // Prepare registration command
    const key: []const u8 = "move";
    const fptr: *const IoC.FactoryFn = &factory_make_move;
    const reg_cmd = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key)), @ptrCast(@constCast(&fptr)));

    var q = core.CommandQueue.init(A);
    defer q.deinit();
    try reg_cmd.call(reg_cmd.ctx, &q);
    if (reg_cmd.drop) |d| d(reg_cmd.ctx, A);

    var ship = fixtures.GoodShip{ .pos = .{ .x = 1, .y = 2 }, .vel = .{ .x = 3, .y = 4 }, .angle = 0, .ang_vel = 0 };

    const cmd = try IoC.Resolve(A, "move", @ptrCast(&ship), null);
    try cmd.call(cmd.ctx, &q);
    if (cmd.drop) |d| d(cmd.ctx, A);

    try testing.expectEqual(@as(f64, 4), ship.pos.x);
    try testing.expectEqual(@as(f64, 6), ship.pos.y);
}

// 2) Scopes.New + Scopes.Current and per-scope factories
test "IoC: scopes provide different strategies per scope" {
    t.tprint("IoC test: scopes new/current with different move strategies\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    const scopeA: []const u8 = "A";
    const scopeB: []const u8 = "B";
    {
        const c = try IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&scopeA)), null);
        try c.call(c.ctx, &q);
        if (c.drop) |d| d(c.ctx, A);
    }
    {
        const c = try IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&scopeB)), null);
        try c.call(c.ctx, &q);
        if (c.drop) |d| d(c.ctx, A);
    }

    // Set current to A and register move (once)
    {
        const c = try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&scopeA)), null);
        try c.call(c.ctx, &q);
        if (c.drop) |d| d(c.ctx, A);
    }
    const key: []const u8 = "move";
    const fA: *const IoC.FactoryFn = &factory_make_move;
    {
        const c = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key)), @ptrCast(@constCast(&fA)));
        try c.call(c.ctx, &q);
        if (c.drop) |d| d(c.ctx, A);
    }

    // Switch to B and register move_twice
    {
        const c = try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&scopeB)), null);
        try c.call(c.ctx, &q);
        if (c.drop) |d| d(c.ctx, A);
    }
    const fB: *const IoC.FactoryFn = &factory_make_move_twice;
    {
        const c = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key)), @ptrCast(@constCast(&fB)));
        try c.call(c.ctx, &q);
        if (c.drop) |d| d(c.ctx, A);
    }

    // In scope B: move twice
    var shipB = fixtures.GoodShip{ .pos = .{ .x = 0, .y = 0 }, .vel = .{ .x = 1, .y = 1 }, .angle = 0, .ang_vel = 0 };
    var cmdB = try IoC.Resolve(A, "move", @ptrCast(&shipB), null);
    try cmdB.call(cmdB.ctx, &q);
    if (cmdB.drop) |d| d(cmdB.ctx, A);
    try testing.expectEqual(@as(f64, 2), shipB.pos.x);
    try testing.expectEqual(@as(f64, 2), shipB.pos.y);

    // Switch back to A: move once
    {
        const c = try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&scopeA)), null);
        try c.call(c.ctx, &q);
        if (c.drop) |d| d(c.ctx, A);
    }
    var shipA = fixtures.GoodShip{ .pos = .{ .x = 10, .y = 10 }, .vel = .{ .x = -3, .y = 5 }, .angle = 0, .ang_vel = 0 };
    var cmdA = try IoC.Resolve(A, "move", @ptrCast(&shipA), null);
    try cmdA.call(cmdA.ctx, &q);
    if (cmdA.drop) |d| d(cmdA.ctx, A);
    try testing.expectEqual(@as(f64, 7), shipA.pos.x);
    try testing.expectEqual(@as(f64, 15), shipA.pos.y);
}

// 3) Multithreaded: each thread has its own current scope
test "IoC: multithreaded current scope isolation" {
    t.tprint("IoC test: multithreaded scope isolation\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    const key: []const u8 = "move";
    const s1: []const u8 = "S1";
    const s2: []const u8 = "S2";

    // Create scopes
    const new1 = try IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&s1)), null);
    const new2 = try IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&s2)), null);
    try new1.call(new1.ctx, &q);
    try new2.call(new2.ctx, &q);
    if (new1.drop) |d| d(new1.ctx, A);
    if (new2.drop) |d| d(new2.ctx, A);

    // Thread 1 work
    var ship1 = fixtures.GoodShip{ .pos = .{ .x = 0, .y = 0 }, .vel = .{ .x = 5, .y = 0 }, .angle = 0, .ang_vel = 0 };
    var ship2 = fixtures.GoodShip{ .pos = .{ .x = 0, .y = 0 }, .vel = .{ .x = 0, .y = 5 }, .angle = 0, .ang_vel = 0 };

    const f1: *const IoC.FactoryFn = &factory_make_move; // S1: move once
    const f2: *const IoC.FactoryFn = &factory_make_move_twice; // S2: move twice

    var c1 = TaskCtx{ .scope = s1, .factory = f1, .ship = &ship1, .key_name = key };
    var c2 = TaskCtx{ .scope = s2, .factory = f2, .ship = &ship2, .key_name = key };
    var th1 = try std.Thread.spawn(.{}, threadMain, .{&c1});
    var th2 = try std.Thread.spawn(.{}, threadMain, .{&c2});

    th1.join();
    th2.join();

    // ship1 moved once (5,0)
    try testing.expectEqual(@as(f64, 5), ship1.pos.x);
    try testing.expectEqual(@as(f64, 0), ship1.pos.y);
    // ship2 moved twice (0,10)
    try testing.expectEqual(@as(f64, 0), ship2.pos.x);
    try testing.expectEqual(@as(f64, 10), ship2.pos.y);
}
