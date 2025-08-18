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

    fn makeKey(self: *MovableAdapter, comptime suffix: []const u8) []const u8 {
        // Compose key into a small temp buffer on the stack; lifetime valid for Resolve call
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ self.iface, suffix }) catch suffix; // fallback
        return key;
    }

    pub fn getPosition(self: *MovableAdapter) !vec.Vec2 {
        var out_val: vec.Vec2 = .{ .x = 0, .y = 0 };
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = self.makeKey("position.get");
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, @ptrCast(&out_val));
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
        return out_val;
    }

    pub fn getVelocity(self: *MovableAdapter) !vec.Vec2 {
        var out_val: vec.Vec2 = .{ .x = 0, .y = 0 };
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = self.makeKey("velocity.get");
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, @ptrCast(&out_val));
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
        return out_val;
    }

    pub fn setPosition(self: *MovableAdapter, new_pos: vec.Vec2) !void {
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = self.makeKey("position.set");
        var tmp = new_pos; // pass pointer to value
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, @ptrCast(&tmp));
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
    }

    pub fn finish(self: *MovableAdapter) !void {
        // Optional extension method per task 3*
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = self.makeKey("finish");
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, null);
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
    }
};
