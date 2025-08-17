const std = @import("std");
const testing = std.testing;
const t = @import("../tests/helpers.zig");
const vec = @import("vector.zig");
const movement = @import("movement.zig");
const rotation = @import("rotation.zig");
const fixtures = @import("fixtures.zig");

const Vec2 = vec.Vec2;
const Movement = movement.Movement;
const Rotation = rotation.Rotation;

// Movement tests (specified in the assignment)
test "Movement: (12,5) + (-7,3) -> (5,8)" {
    t.tprint("Starting movement test: initial pos=(12,5), vel=(-7,3)\n", .{});
    var ship = fixtures.GoodShip{
        .pos = .{ .x = 12, .y = 5 },
        .vel = .{ .x = -7, .y = 3 },
        .angle = 0,
        .ang_vel = 0,
    };

    t.tprint("Stepping movement...\n", .{});
    try Movement.step(&ship);
    t.tprint("After step pos=({any},{any})\n", .{ ship.pos.x, ship.pos.y });
    try testing.expectEqual(@as(f64, 5), ship.pos.x);
    try testing.expectEqual(@as(f64, 8), ship.pos.y);
    t.tprint("OK: movement displacement test passed\n", .{});
}

test "Movement: error when position cannot be read" {
    t.tprint("Starting movement error test: unreadable position\n", .{});
    var bad = fixtures.NoPositionReader{ .vel = .{ .x = 1, .y = 1 } };
    try testing.expectError(error.UnreadablePosition, Movement.step(&bad));
    t.tprint("OK: got expected error UnreadablePosition\n", .{});
}

test "Movement: error when velocity cannot be read" {
    t.tprint("Starting movement error test: unreadable velocity\n", .{});
    var bad = fixtures.NoVelocityReader{ .pos = .{ .x = 0, .y = 0 } };
    try testing.expectError(error.UnreadableVelocity, Movement.step(&bad));
    t.tprint("OK: got expected error UnreadableVelocity\n", .{});
}

test "Movement: error when position cannot be written" {
    t.tprint("Starting movement error test: unwritable position\n", .{});
    var bad = fixtures.NoPositionWriter{ .pos = .{ .x = 0, .y = 0 }, .vel = .{ .x = 1, .y = 1 } };
    try testing.expectError(error.UnwritablePosition, Movement.step(&bad));
    t.tprint("OK: got expected error UnwritablePosition\n", .{});
}

// Rotation tests
test "Rotation: angle increases by angular velocity" {
    t.tprint("Starting rotation test: angle=30, ang_vel=15\n", .{});
    var ship = fixtures.GoodShip{
        .pos = .{ .x = 0, .y = 0 },
        .vel = .{ .x = 0, .y = 0 },
        .angle = 30,
        .ang_vel = 15,
    };

    t.tprint("Stepping rotation...\n", .{});
    try Rotation.step(&ship);
    t.tprint("After step angle={any}\n", .{ship.angle});
    try testing.expectEqual(@as(f64, 45), ship.angle);
    t.tprint("OK: rotation increment test passed\n", .{});
}

test "Rotation: error when orientation cannot be read" {
    t.tprint("Starting rotation error test: unreadable orientation\n", .{});
    var bad = fixtures.NoOrientationReader{ .ang_vel = 5 };
    try testing.expectError(error.UnreadableOrientation, Rotation.step(&bad));
    t.tprint("OK: got expected error UnreadableOrientation\n", .{});
}

test "Rotation: error when orientation cannot be written" {
    t.tprint("Starting rotation error test: unwritable orientation\n", .{});
    var bad = fixtures.NoOrientationWriter{ .angle = 0, .ang_vel = 90 };
    try testing.expectError(error.UnwritableOrientation, Rotation.step(&bad));
    t.tprint("OK: got expected error UnwritableOrientation\n", .{});
}
