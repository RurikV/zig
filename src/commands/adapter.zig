const std = @import("std");
const vec = @import("../space/vector.zig");
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

// Generic interface adapter generator.
// Usage: provide an interface name IFACE and a Spec type that exposes
//   pub fn Methods(comptime Self: type) type { return struct { /* methods */ }; }
// The returned struct will include all methods declared by Spec.Methods(Self)
// and provide IoC helper calls: callOut, callIn, callNoArg.
pub fn InterfaceAdapter(comptime IFACE: []const u8, comptime Spec: type) type {
    _ = Spec;
    return struct {
        allocator: Allocator,
        obj: *anyopaque,

        const Self = @This();

        pub fn init(allocator: Allocator, iface: []const u8, obj: *anyopaque) Self {
            _ = iface; // fixed at comptime by IFACE
            return .{ .allocator = allocator, .obj = obj };
        }

        fn makeKey(self: *Self, comptime suffix: []const u8) ![]u8 {
            return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ IFACE, suffix });
        }

        pub inline fn callOut(self: *Self, comptime suffix: []const u8, out_ptr: anytype) !void {
            var q = core.CommandQueue.init(self.allocator);
            defer q.deinit();
            const key = try self.makeKey(suffix);
            defer self.allocator.free(key);
            const cmd = try IoC.Resolve(self.allocator, key, self.obj, @ptrCast(out_ptr));
            defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
            try cmd.call(cmd.ctx, &q);
        }

        pub inline fn callIn(self: *Self, comptime suffix: []const u8, in_ptr: anytype) !void {
            var q = core.CommandQueue.init(self.allocator);
            defer q.deinit();
            const key = try self.makeKey(suffix);
            defer self.allocator.free(key);
            const cmd = try IoC.Resolve(self.allocator, key, self.obj, @ptrCast(in_ptr));
            defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
            try cmd.call(cmd.ctx, &q);
        }

        pub inline fn callNoArg(self: *Self, comptime suffix: []const u8) !void {
            var q = core.CommandQueue.init(self.allocator);
            defer q.deinit();
            const key = try self.makeKey(suffix);
            defer self.allocator.free(key);
            const cmd = try IoC.Resolve(self.allocator, key, self.obj, null);
            defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
            try cmd.call(cmd.ctx, &q);
        }

        // Default generic methods (exposed regardless of Spec) for common patterns
        // Movable-like
        pub fn getPosition(self: *Self) !vec.Vec2 {
            var out_val: vec.Vec2 = .{ .x = 0, .y = 0 };
            try self.callOut("position.get", &out_val);
            return out_val;
        }
        pub fn getVelocity(self: *Self) !vec.Vec2 {
            var out_val: vec.Vec2 = .{ .x = 0, .y = 0 };
            try self.callOut("velocity.get", &out_val);
            return out_val;
        }
        pub fn setPosition(self: *Self, new_pos: vec.Vec2) !void {
            var tmp = new_pos;
            try self.callIn("position.set", &tmp);
        }
        pub fn finish(self: *Self) !void {
            try self.callNoArg("finish");
        }
        // Fireable-like
        pub fn getAmmo(self: *Self) !u32 {
            var out_val: u32 = 0;
            try self.callOut("ammo.get", &out_val);
            return out_val;
        }
        pub fn fire(self: *Self) !void {
            try self.callNoArg("fire");
        }
        pub fn reload(self: *Self, amount: u32) !void {
            var tmp = amount;
            try self.callIn("reload", &tmp);
        }
    };
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
