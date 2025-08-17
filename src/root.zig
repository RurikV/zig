// New root.zig implementing SOLID-friendly movement and rotation engines with tests
const std = @import("std");
const testing = std.testing;

fn tprint(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[TEST] " ++ fmt, args);
}

// Basic 2D vector type used for position and velocity
pub const Vec2 = struct {
    x: f64,
    y: f64,

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
};

// Engine responsible for straight uniform motion (no deformation, no acceleration)
// It is decoupled from concrete objects and only relies on the object's interface.
// Expected object interface (duck-typed):
//   getPosition(self: *T) !Vec2
//   getVelocity(self: *T) !Vec2
//   setPosition(self: *T, new_pos: Vec2) !void
pub const Movement = struct {
    pub fn step(obj: anytype) !void {
        const pos = try obj.getPosition();
        const vel = try obj.getVelocity();
        try obj.setPosition(Vec2.add(pos, vel));
    }
};

// Engine responsible for rotation around axis
// Expected object interface (duck-typed):
//   getOrientation(self: *T) !f64
//   getAngularVelocity(self: *T) !f64
//   setOrientation(self: *T, new_angle: f64) !void
pub const Rotation = struct {
    pub fn step(obj: anytype) !void {
        const angle = try obj.getOrientation();
        const omega = try obj.getAngularVelocity();
        try obj.setOrientation(angle + omega);
    }
};

// Example implementations used in tests
pub const GoodShip = struct {
    pos: Vec2,
    vel: Vec2,
    angle: f64,
    ang_vel: f64,

    pub fn getPosition(self: *GoodShip) !Vec2 {
        return self.pos;
    }
    pub fn getVelocity(self: *GoodShip) !Vec2 {
        return self.vel;
    }
    pub fn setPosition(self: *GoodShip, p: Vec2) !void {
        self.pos = p;
    }

    pub fn getOrientation(self: *GoodShip) !f64 {
        return self.angle;
    }
    pub fn getAngularVelocity(self: *GoodShip) !f64 {
        return self.ang_vel;
    }
    pub fn setOrientation(self: *GoodShip, a: f64) !void {
        self.angle = a;
    }
};

pub const NoPositionReader = struct {
    vel: Vec2 = .{ .x = 0, .y = 0 },

    pub fn getPosition(_: *NoPositionReader) !Vec2 {
        return error.UnreadablePosition;
    }
    pub fn getVelocity(self: *NoPositionReader) !Vec2 {
        return self.vel;
    }
    pub fn setPosition(_: *NoPositionReader, _: Vec2) !void {
        // pretend to succeed if called; this should not be reached in the failing case
    }
};

pub const NoVelocityReader = struct {
    pos: Vec2 = .{ .x = 0, .y = 0 },

    pub fn getPosition(self: *NoVelocityReader) !Vec2 {
        return self.pos;
    }
    pub fn getVelocity(_: *NoVelocityReader) !Vec2 {
        return error.UnreadableVelocity;
    }
    pub fn setPosition(_: *NoVelocityReader, _: Vec2) !void {}
};

pub const NoPositionWriter = struct {
    pos: Vec2 = .{ .x = 0, .y = 0 },
    vel: Vec2 = .{ .x = 0, .y = 0 },

    pub fn getPosition(self: *NoPositionWriter) !Vec2 {
        return self.pos;
    }
    pub fn getVelocity(self: *NoPositionWriter) !Vec2 {
        return self.vel;
    }
    pub fn setPosition(_: *NoPositionWriter, _: Vec2) !void {
        return error.UnwritablePosition;
    }
};

pub const NoOrientationReader = struct {
    ang_vel: f64 = 0,

    pub fn getOrientation(_: *NoOrientationReader) !f64 {
        return error.UnreadableOrientation;
    }
    pub fn getAngularVelocity(self: *NoOrientationReader) !f64 {
        return self.ang_vel;
    }
    pub fn setOrientation(_: *NoOrientationReader, _: f64) !void {}
};

pub const NoOrientationWriter = struct {
    angle: f64 = 0,
    ang_vel: f64 = 0,

    pub fn getOrientation(self: *NoOrientationWriter) !f64 {
        return self.angle;
    }
    pub fn getAngularVelocity(self: *NoOrientationWriter) !f64 {
        return self.ang_vel;
    }
    pub fn setOrientation(_: *NoOrientationWriter, _: f64) !void {
        return error.UnwritableOrientation;
    }
};

// ------------------ Tests ------------------

// Movement tests (specified in the assignment)
test "Movement: (12,5) + (-7,3) -> (5,8)" {
    tprint("Starting movement test: initial pos=(12,5), vel=(-7,3)\n", .{});
    var ship = GoodShip{
        .pos = .{ .x = 12, .y = 5 },
        .vel = .{ .x = -7, .y = 3 },
        .angle = 0,
        .ang_vel = 0,
    };

    tprint("Stepping movement...\n", .{});
    try Movement.step(&ship);
    tprint("After step pos=({any},{any})\n", .{ ship.pos.x, ship.pos.y });
    try testing.expectEqual(@as(f64, 5), ship.pos.x);
    try testing.expectEqual(@as(f64, 8), ship.pos.y);
    tprint("OK: movement displacement test passed\n", .{});
}

test "Movement: error when position cannot be read" {
    tprint("Starting movement error test: unreadable position\n", .{});
    var bad = NoPositionReader{ .vel = .{ .x = 1, .y = 1 } };
    try testing.expectError(error.UnreadablePosition, Movement.step(&bad));
    tprint("OK: got expected error UnreadablePosition\n", .{});
}

test "Movement: error when velocity cannot be read" {
    tprint("Starting movement error test: unreadable velocity\n", .{});
    var bad = NoVelocityReader{ .pos = .{ .x = 0, .y = 0 } };
    try testing.expectError(error.UnreadableVelocity, Movement.step(&bad));
    tprint("OK: got expected error UnreadableVelocity\n", .{});
}

test "Movement: error when position cannot be written" {
    tprint("Starting movement error test: unwritable position\n", .{});
    var bad = NoPositionWriter{ .pos = .{ .x = 0, .y = 0 }, .vel = .{ .x = 1, .y = 1 } };
    try testing.expectError(error.UnwritablePosition, Movement.step(&bad));
    tprint("OK: got expected error UnwritablePosition\n", .{});
}

// Rotation tests
test "Rotation: angle increases by angular velocity" {
    tprint("Starting rotation test: angle=30, ang_vel=15\n", .{});
    var ship = GoodShip{
        .pos = .{ .x = 0, .y = 0 },
        .vel = .{ .x = 0, .y = 0 },
        .angle = 30,
        .ang_vel = 15,
    };

    tprint("Stepping rotation...\n", .{});
    try Rotation.step(&ship);
    tprint("After step angle={any}\n", .{ ship.angle });
    try testing.expectEqual(@as(f64, 45), ship.angle);
    tprint("OK: rotation increment test passed\n", .{});
}

test "Rotation: error when orientation cannot be read" {
    tprint("Starting rotation error test: unreadable orientation\n", .{});
    var bad = NoOrientationReader{ .ang_vel = 5 };
    try testing.expectError(error.UnreadableOrientation, Rotation.step(&bad));
    tprint("OK: got expected error UnreadableOrientation\n", .{});
}

test "Rotation: error when orientation cannot be written" {
    tprint("Starting rotation error test: unwritable orientation\n", .{});
    var bad = NoOrientationWriter{ .angle = 0, .ang_vel = 90 };
    try testing.expectError(error.UnwritableOrientation, Rotation.step(&bad));
    tprint("OK: got expected error UnwritableOrientation\n", .{});
}
