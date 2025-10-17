// Umbrella root: re-export public API and include tests from split modules
const std = @import("std");

// Public API re-exports for movement/rotation
pub const Vec2 = @import("space/vector.zig").Vec2;
pub const Movement = @import("space/movement.zig").Movement;
pub const Rotation = @import("space/rotation.zig").Rotation;

// Commands namespace: core types and handlers
pub const commands = struct {
    pub const core = @import("commands/core.zig");
    pub const handlers = @import("commands/handlers.zig");
    pub const threading = @import("commands/threading.zig");
};

// Ensure tests from split files are compiled
comptime {
    _ = @import("space/tests_movement_rotation.zig");
    _ = @import("commands/tests_exceptions.zig");
    _ = @import("commands/tests_macro.zig");
    _ = @import("commands/tests_ioc.zig");
    _ = @import("commands/tests_adapter.zig");
    _ = @import("commands/tests_threading.zig");
    _ = @import("commands/tests_endpoint.zig");
    // Include tests from new modules
    _ = @import("space/tests_collision.zig");
    _ = @import("jwt.zig");
    _ = @import("auth.zig");
}
