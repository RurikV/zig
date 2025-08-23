const adapter = @import("adapter.zig");

// Fireable interface spec: declares methods to be mixed into InterfaceAdapter.
pub const FireableSpec = struct {
    pub fn Methods(comptime Self: type) type {
        return struct {
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
};

// Generator alias: ready-to-use AdminFn builder via AdapterAdminBuilder
// After registering with IFACE = "Weapons.IFireable", you can resolve
//   IoC.Resolve(A, "Adapter.Weapons.IFireable", obj_ptr, &out_ptr)
pub const FireableBuilder = adapter.AdapterAdminBuilder(adapter.InterfaceAdapter("Weapons.IFireable", FireableSpec), "Weapons.IFireable");
