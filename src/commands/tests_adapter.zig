const std = @import("std");
const testing = std.testing;
const t = @import("../utils/tests/helpers.zig");
const vec = @import("../space/vector.zig");
const fixtures = @import("../space/fixtures.zig");
const core = @import("core.zig");
const IoC = @import("ioc.zig");
const adapter = @import("adapter.zig");
const fireable = @import("example_fireable_adapter.zig");

const Vec2 = vec.Vec2;

// Define Movable interface Spec and generate adapter types via InterfaceAdapter
const MovableSpec = struct {
    pub fn Adapter(comptime IFACE: []const u8) type {
        return struct {
            allocator: std.mem.Allocator,
            obj: *anyopaque,
            const Self = @This();

            pub fn init(allocator: std.mem.Allocator, iface: []const u8, obj: *anyopaque) Self {
                return adapter.BaseInit(IFACE, Self, allocator, iface, obj);
            }

            pub fn getPosition(self: *Self) !Vec2 {
                var out_val: Vec2 = .{ .x = 0, .y = 0 };
                try adapter.BaseCallOut(IFACE, self.allocator, self.obj, "position.get", &out_val);
                return out_val;
            }
            pub fn getVelocity(self: *Self) !Vec2 {
                var out_val: Vec2 = .{ .x = 0, .y = 0 };
                try adapter.BaseCallOut(IFACE, self.allocator, self.obj, "velocity.get", &out_val);
                return out_val;
            }
            pub fn setPosition(self: *Self, new_pos: Vec2) !void {
                var tmp = new_pos;
                try adapter.BaseCallIn(IFACE, self.allocator, self.obj, "position.set", &tmp);
            }
            pub fn finish(self: *Self) !void {
                try adapter.BaseCallNoArg(IFACE, self.allocator, self.obj, "finish");
            }
        };
    }
};

// Use generated movable adapter type for standard interface
const IF_MOV: []const u8 = "Spaceship.Operations.IMovable";
const Mov = adapter.InterfaceAdapter(IF_MOV, MovableSpec);
const MovMy = adapter.InterfaceAdapter("My.Interface", MovableSpec);
const MovGen = adapter.InterfaceAdapter("Gen.Interface", MovableSpec);

// Helper: register Movable adapter builder once per process using AdapterAdminBuilder
var g_movable_builder_registered: bool = false;
fn register_movable_builder_once(A: std.mem.Allocator, q: *core.CommandQueue) !void {
    if (g_movable_builder_registered) return;
    const Gen = adapter.AdapterAdminBuilder(Mov, IF_MOV);
    const builder: *const IoC.AdminFn = &Gen.make;
    const reg = try IoC.Resolve(A, "Adapter.Register", @ptrCast(@constCast(&IF_MOV)), @ptrCast(@constCast(&builder)));
    defer if (reg.drop) |d| d(reg.ctx, A);
    try reg.call(reg.ctx, q);
    g_movable_builder_registered = true;
}

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

// Negative: adapter methods should error if no factories are registered
// We expect UnknownKey from IoC.Resolve inside adapter method
test "Adapter: getPosition fails with UnknownKey when not registered" {
    t.tprint("Adapter test: missing registrations cause UnknownKey\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    var ship = fixtures.GoodShip{ .pos = .{ .x = 0, .y = 0 }, .vel = .{ .x = 0, .y = 0 }, .angle = 0, .ang_vel = 0 };

    try register_movable_builder_once(A, &q);
    var padapter: *Mov = undefined;
    const make_ad = try IoC.Resolve(A, "Adapter.Spaceship.Operations.IMovable", @ptrCast(@constCast(&ship)), @ptrCast(&padapter));
    defer if (make_ad.drop) |d| d(make_ad.ctx, A);
    try make_ad.call(make_ad.ctx, &q);

    // We did not register "...:position.get" so adapter should fail with UnknownKey
    try testing.expectError(error.UnknownKey, padapter.getPosition());

    A.destroy(padapter);
}

// Scope sensitivity: register different strategies in two scopes and verify adapter honors current scope
const PosGetDoubleCtx = struct { s: *fixtures.GoodShip, out: *Vec2 };
fn exec_pos_get_double(ctx: *PosGetDoubleCtx, _: *core.CommandQueue) !void {
    ctx.out.* = .{ .x = ctx.s.pos.x * 2, .y = ctx.s.pos.y * 2 };
}
fn f_pos_get_double(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const ship: *fixtures.GoodShip = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const pout: *Vec2 = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const Maker = core.CommandFactory(PosGetDoubleCtx, exec_pos_get_double);
    const c = try allocator.create(PosGetDoubleCtx);
    c.* = .{ .s = ship, .out = pout };
    return Maker.makeOwned(c, .flaky, false, false);
}

test "Adapter: delegation uses current IoC scope" {
    t.tprint("Adapter test: scope-sensitive delegation via current scope\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    // Prepare scopes
    const sA: []const u8 = "SA";
    const sB: []const u8 = "SB";
    defer {
        // no explicit scope cleanup needed; state is global across tests
    }
    const cnewA = try IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&sA)), null);
    defer if (cnewA.drop) |d| d(cnewA.ctx, A);
    try cnewA.call(cnewA.ctx, &q);
    const cnewB = try IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&sB)), null);
    defer if (cnewB.drop) |d| d(cnewB.ctx, A);
    try cnewB.call(cnewB.ctx, &q);

    // In SA register normal get_pos
    const csetA = try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&sA)), null);
    defer if (csetA.drop) |d| d(csetA.ctx, A);
    try csetA.call(csetA.ctx, &q);
    const FGetPos: *const IoC.FactoryFn = &f_pos_get;
    var key_pos: []const u8 = "Spaceship.Operations.IMovable:position.get";
    const regA = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_pos)), @ptrCast(@constCast(&FGetPos)));
    defer if (regA.drop) |d| d(regA.ctx, A);
    try regA.call(regA.ctx, &q);

    // In SB register doubled get_pos
    const csetB = try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&sB)), null);
    defer if (csetB.drop) |d| d(csetB.ctx, A);
    try csetB.call(csetB.ctx, &q);
    const FGetPos2: *const IoC.FactoryFn = &f_pos_get_double;
    var key_pos2: []const u8 = "Spaceship.Operations.IMovable:position.get";
    const regB = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_pos2)), @ptrCast(@constCast(&FGetPos2)));
    defer if (regB.drop) |d| d(regB.ctx, A);
    try regB.call(regB.ctx, &q);

    // Build adapter (adapter construction doesn't depend on scope)
    var ship = fixtures.GoodShip{ .pos = .{ .x = 3, .y = 4 }, .vel = .{ .x = 0, .y = 0 }, .angle = 0, .ang_vel = 0 };
    try register_movable_builder_once(A, &q);
    var padapter: *Mov = undefined;
    const make_ad = try IoC.Resolve(A, "Adapter.Spaceship.Operations.IMovable", @ptrCast(@constCast(&ship)), @ptrCast(&padapter));
    defer if (make_ad.drop) |d| d(make_ad.ctx, A);
    try make_ad.call(make_ad.ctx, &q);

    // In SA -> normal
    const setA2 = try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&sA)), null);
    defer if (setA2.drop) |d| d(setA2.ctx, A);
    try setA2.call(setA2.ctx, &q);
    const pA = try padapter.getPosition();
    try testing.expectEqual(@as(f64, 3), pA.x);
    try testing.expectEqual(@as(f64, 4), pA.y);

    // In SB -> doubled
    const setB2 = try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&sB)), null);
    defer if (setB2.drop) |d| d(setB2.ctx, A);
    try setB2.call(setB2.ctx, &q);
    const pB = try padapter.getPosition();
    try testing.expectEqual(@as(f64, 6), pB.x);
    try testing.expectEqual(@as(f64, 8), pB.y);

    A.destroy(padapter);
}

// Adapter.Register: register a custom adapter builder for custom interface name
const MyAdapterBuilderCtx = struct { obj: *anyopaque, out: **MovMy };
fn exec_make_my_adapter(ctx: *MyAdapterBuilderCtx, _: *core.CommandQueue) !void {
    // Build MovableAdapter but with iface "My.Interface"
    const alloc = std.heap.page_allocator; // not used for actual alloc; out already points outside
    // allocate via queue allocator pattern by using out pointer as target
    _ = alloc; // silencing warning; we allocate using caller allocator through IoC
    // no-op; real allocation happens in AdminFn below
    _ = ctx;
}

fn admin_make_my_interface_adapter(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const pobj: *anyopaque = args[0] orelse return error.Invalid;
    const pout: **MovMy = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const a = try allocator.create(MovMy);
    a.* = MovMy.init(allocator, "My.Interface", pobj);
    pout.* = a;
    const Maker = core.CommandFactory(MyAdapterBuilderCtx, exec_make_my_adapter);
    const c = try allocator.create(MyAdapterBuilderCtx);
    c.* = .{ .obj = pobj, .out = pout };
    return Maker.makeOwned(c, .flaky, false, false);
}

test "Adapter: runtime Adapter.Register for custom interface name" {
    t.tprint("Adapter test: Adapter.Register custom builder and delegation\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    // Register custom adapter builder
    const IFACE: []const u8 = "My.Interface";
    const builder: *const IoC.AdminFn = &admin_make_my_interface_adapter;
    const reg_ad = try IoC.Resolve(A, "Adapter.Register", @ptrCast(@constCast(&IFACE)), @ptrCast(@constCast(&builder)));
    defer if (reg_ad.drop) |d| d(reg_ad.ctx, A);
    try reg_ad.call(reg_ad.ctx, &q);

    // Register factories for My.Interface
    const k_get_pos = "My.Interface:position.get";
    const k_set_pos = "My.Interface:position.set";
    const FGetPos: *const IoC.FactoryFn = &f_pos_get;
    const FSetPos: *const IoC.FactoryFn = &f_pos_set;
    var key1: []const u8 = k_get_pos;
    var key2: []const u8 = k_set_pos;
    const reg1 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key1)), @ptrCast(@constCast(&FGetPos)));
    defer if (reg1.drop) |d| d(reg1.ctx, A);
    try reg1.call(reg1.ctx, &q);
    const reg2 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key2)), @ptrCast(@constCast(&FSetPos)));
    defer if (reg2.drop) |d| d(reg2.ctx, A);
    try reg2.call(reg2.ctx, &q);

    // Create adapter via "Adapter.My.Interface"
    var ship = fixtures.GoodShip{ .pos = .{ .x = 2, .y = 2 }, .vel = .{ .x = 0, .y = 0 }, .angle = 0, .ang_vel = 0 };
    var pad: *MovMy = undefined;
    const make_ad = try IoC.Resolve(A, "Adapter.My.Interface", @ptrCast(@constCast(&ship)), @ptrCast(&pad));
    defer if (make_ad.drop) |d| d(make_ad.ctx, A);
    try make_ad.call(make_ad.ctx, &q);

    const p = try pad.getPosition();
    try testing.expectEqual(@as(f64, 2), p.x);
    try testing.expectEqual(@as(f64, 2), p.y);

    try pad.setPosition(.{ .x = 9, .y = 9 });
    const p2 = try pad.getPosition();
    try testing.expectEqual(@as(f64, 9), p2.x);
    try testing.expectEqual(@as(f64, 9), p2.y);

    A.destroy(pad);
}

// Error propagation: failing factory propagates through adapter method
const PosGetFailCtx = struct {};
fn exec_pos_get_fail(_: *PosGetFailCtx, _: *core.CommandQueue) !void {
    return error.FactoryFailure;
}
fn f_pos_get_fail(allocator: std.mem.Allocator, _: [2]?*anyopaque) anyerror!core.Command {
    const Maker = core.CommandFactory(PosGetFailCtx, exec_pos_get_fail);
    const c = try allocator.create(PosGetFailCtx);
    c.* = .{};
    return Maker.makeOwned(c, .flaky, false, false);
}

test "Adapter: method error propagates from failing factory exec" {
    t.tprint("Adapter test: method error propagation from factory\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    // Register failing position.get for standard iface
    const FFail: *const IoC.FactoryFn = &f_pos_get_fail;
    var key: []const u8 = "Spaceship.Operations.IMovable:position.get";
    const reg_fail = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key)), @ptrCast(@constCast(&FFail)));
    defer if (reg_fail.drop) |d| d(reg_fail.ctx, A);
    try reg_fail.call(reg_fail.ctx, &q);

    var ship = fixtures.GoodShip{ .pos = .{ .x = 0, .y = 0 }, .vel = .{ .x = 0, .y = 0 }, .angle = 0, .ang_vel = 0 };
    try register_movable_builder_once(A, &q);
    var pad: *Mov = undefined;
    const make_ad = try IoC.Resolve(A, "Adapter.Spaceship.Operations.IMovable", @ptrCast(@constCast(&ship)), @ptrCast(&pad));
    defer if (make_ad.drop) |d| d(make_ad.ctx, A);
    try make_ad.call(make_ad.ctx, &q);

    const err = pad.getPosition();
    try testing.expectError(error.FactoryFailure, err);

    A.destroy(pad);
}

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
    try register_movable_builder_once(A, &q);
    var padapter: *Mov = undefined;
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
    try register_movable_builder_once(A, &q);
    var padapter: *Mov = undefined;
    const make_ad = try IoC.Resolve(A, "Adapter.Spaceship.Operations.IMovable", @ptrCast(@constCast(&ship)), @ptrCast(&padapter));
    defer if (make_ad.drop) |d| d(make_ad.ctx, A);
    try make_ad.call(make_ad.ctx, &q);

    try padapter.finish();
    const p = try padapter.getPosition();
    try testing.expectEqual(@as(f64, -999), p.x);
    try testing.expectEqual(@as(f64, -999), p.y);

    A.destroy(padapter);
}

// Generator test: use generic AdapterAdminBuilder to register and use a builder for a custom iface
test "Adapter Generator: register and use generated builder" {
    t.tprint("Adapter generator test: register builder for Gen.Interface and delegate\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    // Register factories for Gen.Interface
    const k_get_pos = "Gen.Interface:position.get";
    const k_set_pos = "Gen.Interface:position.set";
    const FGetPos: *const IoC.FactoryFn = &f_pos_get;
    const FSetPos: *const IoC.FactoryFn = &f_pos_set;
    var key1: []const u8 = k_get_pos;
    var key2: []const u8 = k_set_pos;
    const reg1 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key1)), @ptrCast(@constCast(&FGetPos)));
    defer if (reg1.drop) |d| d(reg1.ctx, A);
    try reg1.call(reg1.ctx, &q);
    const reg2 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key2)), @ptrCast(@constCast(&FSetPos)));
    defer if (reg2.drop) |d| d(reg2.ctx, A);
    try reg2.call(reg2.ctx, &q);

    // Generate builder for Movable adapter bound to Gen.Interface and register it
    const Gen = adapter.AdapterAdminBuilder(MovGen, "Gen.Interface");
    const builder: *const IoC.AdminFn = &Gen.make;
    const IFACE: []const u8 = "Gen.Interface";
    const reg_ad = try IoC.Resolve(A, "Adapter.Register", @ptrCast(@constCast(&IFACE)), @ptrCast(@constCast(&builder)));
    defer if (reg_ad.drop) |d| d(reg_ad.ctx, A);
    try reg_ad.call(reg_ad.ctx, &q);

    // Create adapter and verify delegation
    var ship = fixtures.GoodShip{ .pos = .{ .x = 5, .y = 6 }, .vel = .{ .x = 0, .y = 0 }, .angle = 0, .ang_vel = 0 };
    var pad: *MovGen = undefined;
    const make_ad = try IoC.Resolve(A, "Adapter.Gen.Interface", @ptrCast(@constCast(&ship)), @ptrCast(&pad));
    defer if (make_ad.drop) |d| d(make_ad.ctx, A);
    try make_ad.call(make_ad.ctx, &q);

    const p = try pad.getPosition();
    try testing.expectEqual(@as(f64, 5), p.x);
    try testing.expectEqual(@as(f64, 6), p.y);

    try pad.setPosition(.{ .x = 11, .y = 12 });
    const p2 = try pad.getPosition();
    try testing.expectEqual(@as(f64, 11), p2.x);
    try testing.expectEqual(@as(f64, 12), p2.y);

    A.destroy(pad);
}

// ---- FireableAdapter helpers for tests ----
const Weapon = struct { ammo: u32 };

const AmmoGetCtx = struct { w: *Weapon, out: *u32 };
fn exec_ammo_get(ctx: *AmmoGetCtx, _: *core.CommandQueue) !void {
    ctx.out.* = ctx.w.ammo;
}

const FireCtx = struct { w: *Weapon };
fn exec_fire(ctx: *FireCtx, _: *core.CommandQueue) !void {
    if (ctx.w.ammo > 0) ctx.w.ammo -= 1;
}

const ReloadCtx = struct { w: *Weapon, amount: u32 };
fn exec_reload(ctx: *ReloadCtx, _: *core.CommandQueue) !void {
    ctx.w.ammo += ctx.amount;
}

fn f_ammo_get_fireable(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const w: *Weapon = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const pout: *u32 = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const Maker = core.CommandFactory(AmmoGetCtx, exec_ammo_get);
    const c = try allocator.create(AmmoGetCtx);
    c.* = .{ .w = w, .out = pout };
    return Maker.makeOwned(c, .flaky, false, false);
}

fn f_fire_fireable(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const w: *Weapon = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const Maker = core.CommandFactory(FireCtx, exec_fire);
    const c = try allocator.create(FireCtx);
    c.* = .{ .w = w };
    return Maker.makeOwned(c, .flaky, false, false);
}

fn f_reload_fireable(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const w: *Weapon = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const pin: *const u32 = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const Maker = core.CommandFactory(ReloadCtx, exec_reload);
    const c = try allocator.create(ReloadCtx);
    c.* = .{ .w = w, .amount = pin.* };
    return Maker.makeOwned(c, .flaky, false, false);
}

test "Adapter Generator: FireableAdapter for multiple interface names" {
    t.tprint("Adapter generator test: FireableAdapter works for multiple IFACEs\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    // Two different interface names using the same adapter type
    const IFACE1: []const u8 = "Weapons.IFireable";
    const IFACE2: []const u8 = "Alt.IFireable";

    // Register factories for both IFACEs
    const FAmmoGet: *const IoC.FactoryFn = &f_ammo_get_fireable;
    const FFire: *const IoC.FactoryFn = &f_fire_fireable;
    const FReload: *const IoC.FactoryFn = &f_reload_fireable;

    var key_ammo1: []const u8 = "Weapons.IFireable:ammo.get";
    var key_fire1: []const u8 = "Weapons.IFireable:fire";
    var key_reload1: []const u8 = "Weapons.IFireable:reload";

    var key_ammo2: []const u8 = "Alt.IFireable:ammo.get";
    var key_fire2: []const u8 = "Alt.IFireable:fire";
    var key_reload2: []const u8 = "Alt.IFireable:reload";

    const r1 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_ammo1)), @ptrCast(@constCast(&FAmmoGet)));
    defer if (r1.drop) |d| d(r1.ctx, A);
    try r1.call(r1.ctx, &q);
    const r2 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_fire1)), @ptrCast(@constCast(&FFire)));
    defer if (r2.drop) |d| d(r2.ctx, A);
    try r2.call(r2.ctx, &q);
    const r3 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_reload1)), @ptrCast(@constCast(&FReload)));
    defer if (r3.drop) |d| d(r3.ctx, A);
    try r3.call(r3.ctx, &q);

    const r4 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_ammo2)), @ptrCast(@constCast(&FAmmoGet)));
    defer if (r4.drop) |d| d(r4.ctx, A);
    try r4.call(r4.ctx, &q);
    const r5 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_fire2)), @ptrCast(@constCast(&FFire)));
    defer if (r5.drop) |d| d(r5.ctx, A);
    try r5.call(r5.ctx, &q);
    const r6 = try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_reload2)), @ptrCast(@constCast(&FReload)));
    defer if (r6.drop) |d| d(r6.ctx, A);
    try r6.call(r6.ctx, &q);

    // Register adapter builders for both IFACEs using the generic generator
    const Gen1 = adapter.AdapterAdminBuilder(adapter.InterfaceAdapter(IFACE1, fireable.FireableSpec), IFACE1);
    const Gen2 = adapter.AdapterAdminBuilder(adapter.InterfaceAdapter(IFACE2, fireable.FireableSpec), IFACE2);
    const B1: *const IoC.AdminFn = &Gen1.make;
    const B2: *const IoC.AdminFn = &Gen2.make;

    const reg_ad1 = try IoC.Resolve(A, "Adapter.Register", @ptrCast(@constCast(&IFACE1)), @ptrCast(@constCast(&B1)));
    defer if (reg_ad1.drop) |d| d(reg_ad1.ctx, A);
    try reg_ad1.call(reg_ad1.ctx, &q);

    const reg_ad2 = try IoC.Resolve(A, "Adapter.Register", @ptrCast(@constCast(&IFACE2)), @ptrCast(@constCast(&B2)));
    defer if (reg_ad2.drop) |d| d(reg_ad2.ctx, A);
    try reg_ad2.call(reg_ad2.ctx, &q);

    // Create the object and both adapters
    const Fire1 = adapter.InterfaceAdapter(IFACE1, fireable.FireableSpec);
    const Fire2 = adapter.InterfaceAdapter(IFACE2, fireable.FireableSpec);
    var w = Weapon{ .ammo = 5 };
    var ad1: *Fire1 = undefined;
    var ad2: *Fire2 = undefined;

    const mk1 = try IoC.Resolve(A, "Adapter.Weapons.IFireable", @ptrCast(@constCast(&w)), @ptrCast(&ad1));
    defer if (mk1.drop) |d| d(mk1.ctx, A);
    try mk1.call(mk1.ctx, &q);

    const mk2 = try IoC.Resolve(A, "Adapter.Alt.IFireable", @ptrCast(@constCast(&w)), @ptrCast(&ad2));
    defer if (mk2.drop) |d| d(mk2.ctx, A);
    try mk2.call(mk2.ctx, &q);

    // Validate behavior through both adapters referencing the same object
    const a0 = try ad1.getAmmo();
    try testing.expectEqual(@as(u32, 5), a0);

    try ad1.fire(); // ammo: 4
    const a1 = try ad1.getAmmo();
    try testing.expectEqual(@as(u32, 4), a1);

    try ad2.reload(3); // ammo: 7
    const a2 = try ad2.getAmmo();
    try testing.expectEqual(@as(u32, 7), a2);

    try ad2.fire(); // ammo: 6
    const a3 = try ad1.getAmmo();
    try testing.expectEqual(@as(u32, 6), a3);

    A.destroy(ad1);
    A.destroy(ad2);
}
