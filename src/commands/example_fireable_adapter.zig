const std = @import("std");
const core = @import("core.zig");
const IoC = @import("ioc.zig");

const Allocator = std.mem.Allocator;

// Example: FireableAdapter for interface name like "Weapons.IFireable"
// Methods delegate to IoC keys derived from iface string:
//   "<iface>:ammo.get"  args: [ obj_ptr, out_ptr *u32 ]
//   "<iface>:fire"      args: [ obj_ptr, null ]
//   "<iface>:reload"    args: [ obj_ptr, in_ptr *const u32 ]
//
// Usage pattern:
//   - Register factories for the keys above in IoC (per-scope as needed).
//   - Register a builder AdminFn for your interface via "Adapter.Register"
//     (see admin_make_fireable_adapter below), or call it directly as
//       try (try IoC.Resolve(A, "Adapter.Register", &IFACE, &builder)).call(...)
//   - Create adapter via: IoC.Resolve(A, "Adapter.<Iface>", obj_ptr, &out_adapter_ptr)
//   - Call adapter methods: getAmmo(), fire(), reload(x)
pub const FireableAdapter = struct {
    allocator: Allocator,
    iface: []const u8,
    obj: *anyopaque,

    pub fn init(allocator: Allocator, iface: []const u8, obj: *anyopaque) FireableAdapter {
        return .{ .allocator = allocator, .iface = iface, .obj = obj };
    }

    fn makeKey(self: *FireableAdapter, comptime suffix: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ self.iface, suffix });
    }

    inline fn callOut(self: *FireableAdapter, comptime suffix: []const u8, out_ptr: anytype) !void {
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = try self.makeKey(suffix);
        defer self.allocator.free(key);
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, @ptrCast(out_ptr));
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
    }

    inline fn callIn(self: *FireableAdapter, comptime suffix: []const u8, in_ptr: anytype) !void {
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = try self.makeKey(suffix);
        defer self.allocator.free(key);
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, @ptrCast(in_ptr));
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
    }

    inline fn callNoArg(self: *FireableAdapter, comptime suffix: []const u8) !void {
        var q = core.CommandQueue.init(self.allocator);
        defer q.deinit();
        const key = try self.makeKey(suffix);
        defer self.allocator.free(key);
        const cmd = try IoC.Resolve(self.allocator, key, self.obj, null);
        defer if (cmd.drop) |d| d(cmd.ctx, self.allocator);
        try cmd.call(cmd.ctx, &q);
    }

    pub fn getAmmo(self: *FireableAdapter) !u32 {
        var out_val: u32 = 0;
        try self.callOut("ammo.get", &out_val);
        return out_val;
    }

    pub fn fire(self: *FireableAdapter) !void {
        try self.callNoArg("fire");
    }

    pub fn reload(self: *FireableAdapter, amount: u32) !void {
        var tmp = amount;
        try self.callIn("reload", &tmp);
    }
};

// Optional: a ready-to-use AdminFn builder you can register via Adapter.Register
// After registering with IFACE = "Weapons.IFireable", you can resolve
//   IoC.Resolve(A, "Adapter.Weapons.IFireable", obj_ptr, &out_ptr)
pub const FireableAdapterBuilderCtx = struct { obj: *anyopaque, out: **FireableAdapter };
fn execNoop(_: *FireableAdapterBuilderCtx, _: *core.CommandQueue) !void { return; }

pub fn admin_make_fireable_adapter(allocator: Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const pobj: *anyopaque = args[0] orelse return error.Invalid;
    const pout: **FireableAdapter = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const a = try allocator.create(FireableAdapter);
    a.* = FireableAdapter.init(allocator, "Weapons.IFireable", pobj);
    pout.* = a;
    const Maker = core.CommandFactory(FireableAdapterBuilderCtx, execNoop);
    const c = try allocator.create(FireableAdapterBuilderCtx);
    c.* = .{ .obj = pobj, .out = pout };
    return Maker.makeOwned(c, .flaky, false, false);
}
