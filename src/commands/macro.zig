const std = @import("std");
const core = @import("core.zig");
const vec = @import("../space/vector.zig");
const movement = @import("../space/movement.zig");
const rotation = @import("../space/rotation.zig");

// Generic game-level error to surface command-level failures required by assignment
pub const GameError = error{CommandException};

// --------------- MacroCommand -----------------
// A macro command that executes a fixed slice of commands in order.
// If any sub-command fails, execution stops and the error is propagated.
pub const MacroCtx = struct {
    items: []const core.Command,
};

pub fn execMacro(ctx: *MacroCtx, q: *core.CommandQueue) anyerror!void {
    for (ctx.items) |c| {
        try c.call(c.ctx, q);
    }
}

// --------------- Fuel Commands -----------------
// Duck-typed expectations for T (checked at compile-time in exec bodies):
//   getFuel(self: *T) !f64
//   getFuelConsumption(self: *T) !f64  // speed of fuel burn per step
//   setFuel(self: *T, new_amount: f64) !void

pub fn CheckFuelCtx(comptime T: type) type {
    return struct {
        obj: *T,
    };
}

pub fn execCheckFuel(comptime T: type, ctx: *CheckFuelCtx(T), _: *core.CommandQueue) anyerror!void {
    // Compile-time guards to provide clearer error messages if methods are missing
    comptime {
        _ = @hasDecl(T, "getFuel") or @compileError("CheckFuel: T must define getFuel()");
        _ = @hasDecl(T, "getFuelConsumption") or @compileError("CheckFuel: T must define getFuelConsumption()");
    }
    const fuel = try ctx.obj.getFuel();
    const rate = try ctx.obj.getFuelConsumption();
    if (fuel < rate) return GameError.CommandException;
}

pub fn BurnFuelCtx(comptime T: type) type {
    return struct { obj: *T };
}

pub fn execBurnFuel(comptime T: type, ctx: *BurnFuelCtx(T), _: *core.CommandQueue) anyerror!void {
    comptime {
        _ = @hasDecl(T, "getFuel") or @compileError("BurnFuel: T must define getFuel()");
        _ = @hasDecl(T, "getFuelConsumption") or @compileError("BurnFuel: T must define getFuelConsumption()");
        _ = @hasDecl(T, "setFuel") or @compileError("BurnFuel: T must define setFuel(f64)");
    }
    const fuel = try ctx.obj.getFuel();
    const rate = try ctx.obj.getFuelConsumption();
    const new_amount = fuel - rate;
    if (new_amount < 0) return GameError.CommandException; // safety net
    try ctx.obj.setFuel(new_amount);
}

// --------------- Movement/Rotation wrappers as Commands -----------------

pub fn MoveCtx(comptime T: type) type {
    return struct { obj: *T };
}

pub fn execMove(comptime T: type, ctx: *MoveCtx(T), _: *core.CommandQueue) anyerror!void {
    try movement.Movement.step(ctx.obj);
}

pub fn RotateCtx(comptime T: type) type {
    return struct { obj: *T };
}

pub fn execRotate(comptime T: type, ctx: *RotateCtx(T), _: *core.CommandQueue) anyerror!void {
    try rotation.Rotation.step(ctx.obj);
}

// --------------- ChangeVelocityCommand -----------------
// Rotates instantaneous velocity vector by the same delta used for the rotation step (omega).
// Some rotating objects may not move; in such cases, do nothing.

inline fn hasVelocityAPI(comptime T: type) bool {
    return @hasDecl(T, "getVelocity") and @hasDecl(T, "setVelocity");
}

pub fn ChangeVelCtx(comptime T: type) type {
    return struct { obj: *T };
}

pub fn execChangeVelocity(comptime T: type, ctx: *ChangeVelCtx(T), _: *core.CommandQueue) anyerror!void {
    // Always need orientation and angular velocity to know delta
    comptime {
        _ = @hasDecl(T, "getOrientation") or @compileError("ChangeVelocity: T must define getOrientation()");
        _ = @hasDecl(T, "getAngularVelocity") or @compileError("ChangeVelocity: T must define getAngularVelocity()");
    }
    const omega = try ctx.obj.getAngularVelocity(); // delta applied in corresponding Rotate step

    // If velocity API is missing, this is a no-op by requirement
    if (!comptime hasVelocityAPI(T)) return;

    const v = try ctx.obj.getVelocity();
    if (v.x == 0 and v.y == 0) return; // rotating zero vector yields zero

    const cos_a = std.math.cos(omega);
    const sin_a = std.math.sin(omega);
    const nx = v.x * cos_a - v.y * sin_a;
    const ny = v.x * sin_a + v.y * cos_a;
    try ctx.obj.setVelocity(.{ .x = nx, .y = ny });
}


// --------------- Bridge, NoOp, and Repeater Commands -----------------
// Bridge: delegates to a dynamically swappable inner command.
pub const BridgeCtx = struct {
    inner: core.Command,
};

pub fn execBridge(ctx: *BridgeCtx, q: *core.CommandQueue) anyerror!void {
    // Delegate to current inner
    try ctx.inner.call(ctx.inner.ctx, q);
}

// NoOp: does nothing
pub const NoOpCtx = struct {};
pub fn execNoOp(_: *NoOpCtx, _: *core.CommandQueue) anyerror!void {
    // intentionally empty
    return;
}

// Repeater: re-enqueues the target command back to the queue (front) for continuous behavior.
pub const RepeaterCtx = struct { target: core.Command };
pub fn execRepeater(ctx: *RepeaterCtx, q: *core.CommandQueue) anyerror!void {
    // Place at front so that repetition is immediate; can be changed to pushBack for different cadence
    try q.pushFront(ctx.target);
}
