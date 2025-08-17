const std = @import("std");

// Basic 2D vector type used for position and velocity
pub const Vec2 = struct {
    x: f64,
    y: f64,

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
};
