const std = @import("std");
const testing = std.testing;
const t = @import("../utils/tests/helpers.zig");
const vec = @import("../space/vector.zig");
const fixtures = @import("../space/fixtures.zig");
const core = @import("core.zig");
const IoC = @import("ioc.zig");
const adapter = @import("adapter.zig");

const Vec2 = vec.Vec2;

// ---- Top-level contexts and execs for factories ----
const PosGetCtx = struct { s: *fixtures.GoodShip, out: *Vec2 };
fn exec_pos_get(ctx: *PosGetCtx, _: *core.CommandQueue) !void {
    ctx.out.* = ctx.s.pos;
}

const VelGetCtx = struct { s: *fixtures.GoodShip, out: *Vec2 };
fn exec_vel_get(ctx: *VelGetCtx, _: *core.CommandQueue) !void {
    ctx.out.* = ctx.s.vel;
}

const PosSetCtx = struct { s: *fixtures.GoodShip, v: Vec2 };
fn exec_pos_set(ctx: *PosSetCtx, _: *core.CommandQueue) !void {
    ctx.s.pos = ctx.v;
}

const FinishCtx = struct { s: *fixtures.GoodShip };
fn exec_finish(ctx: *FinishCtx, _: *core.CommandQueue) !void {
    ctx.s.pos = .{ .x = -999, .y = -999 };
}

// ---- Factories for IMovable operations over fixtures.GoodShip ----
// position.get: args[0] = *GoodShip, args[1] = *Vec2 (out)
fn f_pos_get(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const ship: *fixtures.GoodShip = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const pout: *Vec2 = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const Maker = core.CommandFactory(PosGetCtx, exec_pos_get);
    const c = try allocator.create(PosGetCtx);
    c.* = .{ .s = ship, .out = pout };
    return Maker.makeOwned(c, .flaky, false, false);
}

// velocity.get: args[0] = *GoodShip, args[1] = *Vec2 (out)
fn f_vel_get(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const ship: *fixtures.GoodShip = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const pout: *Vec2 = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const Maker = core.CommandFactory(VelGetCtx, exec_vel_get);
    const c = try allocator.create(VelGetCtx);
    c.* = .{ .s = ship, .out = pout };
    return Maker.makeOwned(c, .flaky, false, false);
}

// position.set: args[0] = *GoodShip, args[1] = *const Vec2 (in)
fn f_pos_set(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const ship: *fixtures.GoodShip = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const pin: *const Vec2 = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const Maker = core.CommandFactory(PosSetCtx, exec_pos_set);
    const c = try allocator.create(PosSetCtx);
    c.* = .{ .s = ship, .v = pin.* };
    return Maker.makeOwned(c, .flaky, false, false);
}

// Optional finish: args[0] = *GoodShip
fn f_finish(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const ship: *fixtures.GoodShip = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const Maker = core.CommandFactory(FinishCtx, exec_finish);
    const c = try allocator.create(FinishCtx);
    c.* = .{ .s = ship };
    return Maker.makeOwned(c, .flaky, false, false);
}

// ------------------ Tests ------------------

test "Adapter: MovableAdapter via IoC admin op and method delegation" {
    t.tprint("Adapter test: generate MovableAdapter and delegate via IoC\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    // Register factories for interface operations
    const k_get_pos = "Spaceship.Operations.IMovable:position.get";
    const k_get_vel = "Spaceship.Operations.IMovable:velocity.get";
    const k_set_pos = "Spaceship.Operations.IMovable:position.set";

    const FGetPos: *const IoC.FactoryFn = &f_pos_get;
    const FGetVel: *const IoC.FactoryFn = &f_vel_get;
    const FSetPos: *const IoC.FactoryFn = &f_pos_set;

    var key_pos: []const u8 = k_get_pos;
    const reg1 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_pos)), @ptrCast(@constCast(&FGetPos)));
    defer if (reg1.drop) |d| d(reg1.ctx, A);
    try reg1.call(reg1.ctx, &q);
    var key_vel: []const u8 = k_get_vel;
    const reg2 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_vel)), @ptrCast(@constCast(&FGetVel)));
    defer if (reg2.drop) |d| d(reg2.ctx, A);
    try reg2.call(reg2.ctx, &q);
    var key_set: []const u8 = k_set_pos;
    const reg3 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_set)), @ptrCast(@constCast(&FSetPos)));
    defer if (reg3.drop) |d| d(reg3.ctx, A);
    try reg3.call(reg3.ctx, &q);

    // Prepare object
    var ship = fixtures.GoodShip{ .pos = .{ .x = 1, .y = 2 }, .vel = .{ .x = 3, .y = 4 }, .angle = 0, .ang_vel = 0 };

    // Use IoC admin op to allocate adapter and receive it via out pointer
    var padapter: *adapter.MovableAdapter = undefined;
    const make_ad = try IoC.Resolve(A, "Adapter.Spaceship.Operations.IMovable", @ptrCast(@constCast(&ship)), @ptrCast(&padapter));
    defer if (make_ad.drop) |d| d(make_ad.ctx, A);
    try make_ad.call(make_ad.ctx, &q);

    // Verify adapter methods delegate to IoC
    const p0 = try padapter.getPosition();
    try testing.expectEqual(@as(f64, 1), p0.x);
    try testing.expectEqual(@as(f64, 2), p0.y);

    const v0 = try padapter.getVelocity();
    try testing.expectEqual(@as(f64, 3), v0.x);
    try testing.expectEqual(@as(f64, 4), v0.y);

    try padapter.setPosition(.{ .x = 10, .y = 20 });
    const p1 = try padapter.getPosition();
    try testing.expectEqual(@as(f64, 10), p1.x);
    try testing.expectEqual(@as(f64, 20), p1.y);

    // Clean up
    A.destroy(padapter);
}

test "Adapter: optional finish() method delegates to IoC" {
    t.tprint("Adapter test: optional finish() via IoC\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    const k_finish = "Spaceship.Operations.IMovable:finish";
    const FFinish: *const IoC.FactoryFn = &f_finish;

    var key_finish: []const u8 = k_finish;
    const regf = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_finish)), @ptrCast(@constCast(&FFinish)));
    defer if (regf.drop) |d| d(regf.ctx, A);
    try regf.call(regf.ctx, &q);

    var ship = fixtures.GoodShip{ .pos = .{ .x = 7, .y = 8 }, .vel = .{ .x = 0, .y = 0 }, .angle = 0, .ang_vel = 0 };
    var padapter: *adapter.MovableAdapter = undefined;
    const make_ad = try IoC.Resolve(A, "Adapter.Spaceship.Operations.IMovable", @ptrCast(@constCast(&ship)), @ptrCast(&padapter));
    defer if (make_ad.drop) |d| d(make_ad.ctx, A);
    try make_ad.call(make_ad.ctx, &q);

    try padapter.finish();
    const p = try padapter.getPosition();
    try testing.expectEqual(@as(f64, -999), p.x);
    try testing.expectEqual(@as(f64, -999), p.y);

    A.destroy(padapter);
}
