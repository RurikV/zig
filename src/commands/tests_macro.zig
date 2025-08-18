const std = @import("std");
const testing = std.testing;
const t = @import("../utils/tests/helpers.zig");
const vec = @import("../space/vector.zig");
const movement = @import("../space/movement.zig");
const rotation = @import("../space/rotation.zig");
const core = @import("core.zig");
const macro = @import("macro.zig");

const CommandFactory = core.CommandFactory;

// Concrete exec thunks for generic command execs used in this test
fn execCheckFuel_Ship(ctx: *macro.CheckFuelCtx(ShipWithFuel), q: *core.CommandQueue) anyerror!void {
    return macro.execCheckFuel(ShipWithFuel, ctx, q);
}
fn execBurnFuel_Ship(ctx: *macro.BurnFuelCtx(ShipWithFuel), q: *core.CommandQueue) anyerror!void {
    return macro.execBurnFuel(ShipWithFuel, ctx, q);
}
fn execMove_Ship(ctx: *macro.MoveCtx(ShipWithFuel), q: *core.CommandQueue) anyerror!void {
    return macro.execMove(ShipWithFuel, ctx, q);
}
fn execRotate_Ship(ctx: *macro.RotateCtx(ShipWithFuel), q: *core.CommandQueue) anyerror!void {
    return macro.execRotate(ShipWithFuel, ctx, q);
}
fn execChangeVel_Ship(ctx: *macro.ChangeVelCtx(ShipWithFuel), q: *core.CommandQueue) anyerror!void {
    return macro.execChangeVelocity(ShipWithFuel, ctx, q);
}

fn execRotate_Turret(ctx: *macro.RotateCtx(RotatorOnly), q: *core.CommandQueue) anyerror!void {
    return macro.execRotate(RotatorOnly, ctx, q);
}
fn execChangeVel_Turret(ctx: *macro.ChangeVelCtx(RotatorOnly), q: *core.CommandQueue) anyerror!void {
    return macro.execChangeVelocity(RotatorOnly, ctx, q);
}

// -------- Fixtures with fuel --------
const ShipWithFuel = struct {
    // movement/rotation
    pos: vec.Vec2 = .{ .x = 0, .y = 0 },
    vel: vec.Vec2 = .{ .x = 0, .y = 0 },
    angle: f64 = 0,
    ang_vel: f64 = 0,
    // fuel
    fuel: f64 = 0,
    burn: f64 = 0,

    pub fn getPosition(self: *ShipWithFuel) !vec.Vec2 {
        return self.pos;
    }
    pub fn getVelocity(self: *ShipWithFuel) !vec.Vec2 {
        return self.vel;
    }
    pub fn setPosition(self: *ShipWithFuel, p: vec.Vec2) !void {
        self.pos = p;
    }
    pub fn setVelocity(self: *ShipWithFuel, v: vec.Vec2) !void {
        self.vel = v;
    }

    pub fn getOrientation(self: *ShipWithFuel) !f64 {
        return self.angle;
    }
    pub fn getAngularVelocity(self: *ShipWithFuel) !f64 {
        return self.ang_vel;
    }
    pub fn setOrientation(self: *ShipWithFuel, a: f64) !void {
        self.angle = a;
    }

    pub fn getFuel(self: *ShipWithFuel) !f64 {
        return self.fuel;
    }
    pub fn getFuelConsumption(self: *ShipWithFuel) !f64 {
        return self.burn;
    }
    pub fn setFuel(self: *ShipWithFuel, v: f64) !void {
        self.fuel = v;
    }
};

// Fixture that rotates but has no velocity API
const RotatorOnly = struct {
    angle: f64 = 0,
    ang_vel: f64 = 0,

    pub fn getOrientation(self: *RotatorOnly) !f64 {
        return self.angle;
    }
    pub fn getAngularVelocity(self: *RotatorOnly) !f64 {
        return self.ang_vel;
    }
    pub fn setOrientation(self: *RotatorOnly, a: f64) !void {
        self.angle = a;
    }
};

const SuccCtx = struct { ran: *bool };
fn execSucc(ctx: *SuccCtx, _: *core.CommandQueue) !void {
    ctx.ran.* = true;
}
const FailCtx = struct {};
fn execFail(_: *FailCtx, _: *core.CommandQueue) !void {
    return macro.GameError.CommandException;
}

// ---------- Tests ----------

// 1) CheckFuelCommand tests
test "Macro: CheckFuelCommand success and failure" {
    t.tprint("Macro test: CheckFuelCommand success and failure\n", .{});

    var ship_ok = ShipWithFuel{ .fuel = 10, .burn = 3 };
    var ctx_ok = macro.CheckFuelCtx(ShipWithFuel){ .obj = &ship_ok };
    try macro.execCheckFuel(ShipWithFuel, &ctx_ok, undefined);

    var ship_bad = ShipWithFuel{ .fuel = 2, .burn = 3 };
    var ctx_bad = macro.CheckFuelCtx(ShipWithFuel){ .obj = &ship_bad };
    try testing.expectError(macro.GameError.CommandException, macro.execCheckFuel(ShipWithFuel, &ctx_bad, undefined));
}

// 2) BurnFuelCommand test
test "Macro: BurnFuelCommand reduces fuel" {
    t.tprint("Macro test: BurnFuelCommand reduces fuel\n", .{});
    var ship = ShipWithFuel{ .fuel = 10, .burn = 2 };
    var ctx = macro.BurnFuelCtx(ShipWithFuel){ .obj = &ship };
    try macro.execBurnFuel(ShipWithFuel, &ctx, undefined);
    try testing.expectEqual(@as(f64, 8), ship.fuel);
}

// 3) MacroCommand stops on error and propagates
test "Macro: MacroCommand aborts on first failure" {
    t.tprint("Macro test: MacroCommand aborts on first failure\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    // Define a trivial success command and a failing command (declared above)

    var ran1: bool = false;
    var ran2: bool = false;

    const make_succ = CommandFactory(SuccCtx, execSucc);
    const make_fail = CommandFactory(FailCtx, execFail);

    var c1_ctx = SuccCtx{ .ran = &ran1 };
    var c2_ctx = FailCtx{};
    var c3_ctx = SuccCtx{ .ran = &ran2 };

    const c1 = make_succ.make(&c1_ctx, .flaky);
    const c2 = make_fail.make(&c2_ctx, .always_fails);
    const c3 = make_succ.make(&c3_ctx, .flaky);

    var items = [_]core.Command{ c1, c2, c3 };
    var mctx = macro.MacroCtx{ .items = items[0..] };

    var q = core.CommandQueue.init(A);
    defer q.deinit();
    const mmake = CommandFactory(macro.MacroCtx, macro.execMacro);
    const mcmd = mmake.make(&mctx, .flaky);

    try testing.expectError(macro.GameError.CommandException, mcmd.call(mcmd.ctx, &q));
    try testing.expect(ran1);
    try testing.expect(!ran2);
}

// 4) Fuel-aware movement macro: [CheckFuel, Move, BurnFuel]
test "Macro: movement with fuel consumption" {
    t.tprint("Macro test: movement with fuel consumption\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var ship = ShipWithFuel{
        .pos = .{ .x = 12, .y = 5 },
        .vel = .{ .x = -7, .y = 3 },
        .fuel = 10,
        .burn = 2,
    };

    const make_check = CommandFactory(macro.CheckFuelCtx(ShipWithFuel), execCheckFuel_Ship);
    const make_move = CommandFactory(macro.MoveCtx(ShipWithFuel), execMove_Ship);
    const make_burn = CommandFactory(macro.BurnFuelCtx(ShipWithFuel), execBurnFuel_Ship);

    var c1 = macro.CheckFuelCtx(ShipWithFuel){ .obj = &ship };
    var c2 = macro.MoveCtx(ShipWithFuel){ .obj = &ship };
    var c3 = macro.BurnFuelCtx(ShipWithFuel){ .obj = &ship };

    const cmds = [_]core.Command{
        make_check.make(&c1, .flaky),
        make_move.make(&c2, .flaky),
        make_burn.make(&c3, .flaky),
    };

    var mctx = macro.MacroCtx{ .items = cmds[0..] };
    var q = core.CommandQueue.init(A);
    defer q.deinit();
    const mmake = CommandFactory(macro.MacroCtx, macro.execMacro);
    const mcmd = mmake.make(&mctx, .flaky);

    try mcmd.call(mcmd.ctx, &q);

    try testing.expectEqual(@as(f64, 5), ship.pos.x);
    try testing.expectEqual(@as(f64, 8), ship.pos.y);
    try testing.expectEqual(@as(f64, 8), ship.fuel);
}

// 5) ChangeVelocityCommand rotates velocity by omega; 6) Rotation macro includes ChangeVelocity

test "Macro: ChangeVelocity rotates velocity and rotation macro works" {
    t.tprint("Macro test: ChangeVelocity rotates velocity and rotation macro\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var ship = ShipWithFuel{
        .vel = .{ .x = 1, .y = 0 },
        .ang_vel = std.math.pi / 2.0,
        .angle = 0,
    };
    const make_rot = CommandFactory(macro.RotateCtx(ShipWithFuel), execRotate_Ship);
    const make_chv = CommandFactory(macro.ChangeVelCtx(ShipWithFuel), execChangeVel_Ship);

    var rctx = macro.RotateCtx(ShipWithFuel){ .obj = &ship };
    var vctx = macro.ChangeVelCtx(ShipWithFuel){ .obj = &ship };

    const seq = [_]core.Command{ make_rot.make(&rctx, .flaky), make_chv.make(&vctx, .flaky) };

    var mctx = macro.MacroCtx{ .items = seq[0..] };
    var q = core.CommandQueue.init(A);
    defer q.deinit();
    const mmake = CommandFactory(macro.MacroCtx, macro.execMacro);
    const mcmd = mmake.make(&mctx, .flaky);

    try mcmd.call(mcmd.ctx, &q);

    // angle applied
    try testing.expectApproxEqAbs(std.math.pi / 2.0, ship.angle, 1e-9);
    // velocity rotated +90 degrees -> (0,1)
    try testing.expectApproxEqAbs(0.0, ship.vel.x, 1e-9);
    try testing.expectApproxEqAbs(1.0, ship.vel.y, 1e-9);
}

// 6) ChangeVelocity does nothing for objects without velocity

test "Macro: ChangeVelocity no-op for rotator without velocity" {
    t.tprint("Macro test: ChangeVelocity no-op for object without velocity\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var turret = RotatorOnly{ .angle = 0, .ang_vel = std.math.pi / 4.0 };

    const make_rot = CommandFactory(macro.RotateCtx(RotatorOnly), execRotate_Turret);
    const make_chv = CommandFactory(macro.ChangeVelCtx(RotatorOnly), execChangeVel_Turret);

    var rctx = macro.RotateCtx(RotatorOnly){ .obj = &turret };
    var vctx = macro.ChangeVelCtx(RotatorOnly){ .obj = &turret };

    const seq = [_]core.Command{ make_rot.make(&rctx, .flaky), make_chv.make(&vctx, .flaky) };
    var mctx = macro.MacroCtx{ .items = seq[0..] };

    var q = core.CommandQueue.init(A);
    defer q.deinit();
    const mmake = CommandFactory(macro.MacroCtx, macro.execMacro);
    const mcmd = mmake.make(&mctx, .flaky);

    try mcmd.call(mcmd.ctx, &q);

    try testing.expectApproxEqAbs(std.math.pi / 4.0, turret.angle, 1e-9);
}
