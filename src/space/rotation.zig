pub const Rotation = struct {
    pub fn step(obj: anytype) !void {
        const angle = try obj.getOrientation();
        const omega = try obj.getAngularVelocity();
        try obj.setOrientation(angle + omega);
    }
};
