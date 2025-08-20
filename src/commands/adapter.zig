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
pub const MovableAdapter = struct {
    allocator: Allocator,
    iface: []const u8,
    obj: *anyopaque,

    pub fn init(allocator: Allocator, iface: []const u8, obj: *anyopaque) MovableAdapter {
        return .{ .allocator = allocator, .iface = iface, .obj = obj };
    }

    fn makeKey(self: *MovableAdapter, comptime suffix: []const u8) ![]u8 {
        // Allocate a key string "<iface>:<suffix>" owned by self.allocator; caller must free.
        return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ self.iface, suffix });
    }

    inline fn callOut(self: *MovableAdapter, comptime suffix: []const u8, out_ptr: anytype) !void {
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = try self.makeKey(suffix);
        defer self.allocator.free(key);
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, @ptrCast(out_ptr));
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
    }

    inline fn callIn(self: *MovableAdapter, comptime suffix: []const u8, in_ptr: anytype) !void {
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = try self.makeKey(suffix);
        defer self.allocator.free(key);
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, @ptrCast(in_ptr));
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
    }

    inline fn callNoArg(self: *MovableAdapter, comptime suffix: []const u8) !void {
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = try self.makeKey(suffix);
        defer self.allocator.free(key);
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, null);
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
    }

    pub fn getPosition(self: *MovableAdapter) !vec.Vec2 {
        var out_val: vec.Vec2 = .{ .x = 0, .y = 0 };
        try self.callOut("position.get", &out_val);
        return out_val;
    }

    pub fn getVelocity(self: *MovableAdapter) !vec.Vec2 {
        var out_val: vec.Vec2 = .{ .x = 0, .y = 0 };
        try self.callOut("velocity.get", &out_val);
        return out_val;
    }

    pub fn setPosition(self: *MovableAdapter, new_pos: vec.Vec2) !void {
        var tmp = new_pos; // pass pointer to value
        try self.callIn("position.set", &tmp);
    }

    pub fn finish(self: *MovableAdapter) !void {
        // Optional extension method per task 3*
        try self.callNoArg("finish");
    }
};
