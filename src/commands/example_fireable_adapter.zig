const std = @import("std");
const core = @import("core.zig");
const IoC = @import("ioc.zig");
const adapter = @import("adapter.zig");

// Fireable interface spec: provides its own Adapter(IFACE) type with helpers and methods.
pub const FireableSpec = struct {
    pub fn Adapter(comptime IFACE: []const u8) type {
        return struct {
            allocator: std.mem.Allocator,
            obj: *anyopaque,
            const Self = @This();

            pub fn init(allocator: std.mem.Allocator, iface: []const u8, obj: *anyopaque) Self {
                return adapter.BaseInit(IFACE, Self, allocator, iface, obj);
            }

            pub fn getAmmo(self: *Self) !u32 {
                var out_val: u32 = 0;
                try adapter.BaseCallOut(IFACE, self.allocator, self.obj, "ammo.get", &out_val);
                return out_val;
            }
            pub fn fire(self: *Self) !void {
                try adapter.BaseCallNoArg(IFACE, self.allocator, self.obj, "fire");
            }
            pub fn reload(self: *Self, amount: u32) !void {
                var tmp = amount;
                try adapter.BaseCallIn(IFACE, self.allocator, self.obj, "reload", &tmp);
            }
        };
    }
};

// Generator alias: ready-to-use AdminFn builder via AdapterAdminBuilder
// After registering with IFACE = "Weapons.IFireable", you can resolve
//   IoC.Resolve(A, "Adapter.Weapons.IFireable", obj_ptr, &out_ptr)
pub const FireableBuilder = adapter.AdapterAdminBuilder(adapter.InterfaceAdapter("Weapons.IFireable", FireableSpec), "Weapons.IFireable");
