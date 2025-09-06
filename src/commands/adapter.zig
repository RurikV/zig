const std = @import("std");
const core = @import("core.zig");
const IoC = @import("ioc.zig");

const Allocator = std.mem.Allocator;

// Adapter for Spaceship.Operations.IMovable-like interfaces.
// The adapter does not know the concrete object type; it calls IoC to perform operations.
// Expected IoC keys (factories must be registered by the application/tests):
//   "<iface>:position.get"  args: [ obj_ptr, out_ptr *vec.Vec2 ]
//   "<iface>:velocity.get"  args: [ obj_ptr, out_ptr *vec.Vec2 ]
//   "<iface>:position.set"  args: [ obj_ptr, in_ptr  *const vec.Vec2 ]
// Optional (for task 3*):
//   "<iface>:finish"        args: [ obj_ptr, null ]

// --------------- Base Adapter (common helpers) ---------------
// Provides common helper functions (init/makeKey/call*) parametrized by IFACE and Self.
// Usage inside a Spec.Adapter(IFACE):
//   return struct {
//       allocator: std.mem.Allocator,
//       obj: *anyopaque,
//       const Self = @This();
//       usingnamespace adapter.BaseMethods(IFACE, Self);
//       // ... interface-specific methods ...
//   };
// Base helpers as free functions (can be used by any Spec without mixins)
pub fn BaseInit(comptime IFACE: []const u8, comptime Self: type, allocator: std.mem.Allocator, iface: []const u8, obj: *anyopaque) Self {
    _ = IFACE;
    _ = iface; // fixed at comptime by IFACE
    return .{ .allocator = allocator, .obj = obj };
}

pub fn BaseMakeKey(comptime IFACE: []const u8, allocator: std.mem.Allocator, comptime suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ IFACE, suffix });
}

pub fn BaseCallOut(comptime IFACE: []const u8, allocator: std.mem.Allocator, obj: *anyopaque, comptime suffix: []const u8, out_ptr: anytype) !void {
    var q = core.CommandQueue.init(allocator);
    defer q.deinit();
    const key = try BaseMakeKey(IFACE, allocator, suffix);
    defer allocator.free(key);
    const cmd = try IoC.Resolve(allocator, key, obj, @ptrCast(out_ptr));
    defer if (cmd.drop) |d| d(cmd.ctx, allocator);
    try cmd.call(cmd.ctx, &q);
}

pub fn BaseCallIn(comptime IFACE: []const u8, allocator: std.mem.Allocator, obj: *anyopaque, comptime suffix: []const u8, in_ptr: anytype) !void {
    var q = core.CommandQueue.init(allocator);
    defer q.deinit();
    const key = try BaseMakeKey(IFACE, allocator, suffix);
    defer allocator.free(key);
    const cmd = try IoC.Resolve(allocator, key, obj, @ptrCast(in_ptr));
    defer if (cmd.drop) |d| d(cmd.ctx, allocator);
    try cmd.call(cmd.ctx, &q);
}

pub fn BaseCallNoArg(comptime IFACE: []const u8, allocator: std.mem.Allocator, obj: *anyopaque, comptime suffix: []const u8) !void {
    var q = core.CommandQueue.init(allocator);
    defer q.deinit();
    const key = try BaseMakeKey(IFACE, allocator, suffix);
    defer allocator.free(key);
    const cmd = try IoC.Resolve(allocator, key, obj, null);
    defer if (cmd.drop) |d| d(cmd.ctx, allocator);
    try cmd.call(cmd.ctx, &q);
}

// --------------- Generic interface adapter generator ---------------
// Delegates type definition entirely to Spec.
// Spec must expose: pub fn Adapter(comptime IFACE: []const u8) type { /* returns a type with init and methods */ }
pub fn InterfaceAdapter(comptime IFACE: []const u8, comptime Spec: type) type {
    return Spec.Adapter(IFACE);
}

// ---------------- Generic Adapter Builder Generator ----------------
// Provides a ready-to-register AdminFn that builds an adapter of type T for a fixed interface name.
// Usage:
//   const T = InterfaceAdapter("My.Interface", SomeSpec);
//   const Gen = AdapterAdminBuilder(T, "My.Interface");
//   const fnptr: *const IoC.AdminFn = &Gen.make;
//   // register via IoC.Resolve(A, "Adapter.Register", &iface, &fnptr)
pub fn AdapterAdminBuilder(comptime T: type, comptime IFACE: []const u8) type {
    return struct {
        const Ctx = struct { obj: *anyopaque, out: **T };
        fn execNoop(_: *Ctx, _: *core.CommandQueue) !void {
            return;
        }
        pub fn make(allocator: Allocator, args: [2]?*anyopaque) anyerror!core.Command {
            const pobj: *anyopaque = args[0] orelse return error.Invalid;
            const pout: **T = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
            const a = try allocator.create(T);
            a.* = T.init(allocator, IFACE, pobj);
            pout.* = a;
            const Maker = core.CommandFactory(Ctx, execNoop);
            const c = try allocator.create(Ctx);
            c.* = .{ .obj = pobj, .out = pout };
            return Maker.makeOwned(c, .flaky, false, false);
        }
    };
}
