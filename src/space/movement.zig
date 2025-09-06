const vec = @import("vector.zig");

pub const Movement = struct {
    pub fn step(obj: anytype) !void {
        const pos = try obj.getPosition();
        const vel = try obj.getVelocity();
        try obj.setPosition(vec.Vec2.add(pos, vel));
    }
};
