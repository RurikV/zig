const vec = @import("vector.zig");

pub const GoodShip = struct {
    pos: vec.Vec2,
    vel: vec.Vec2,
    angle: f64,
    ang_vel: f64,

    pub fn getPosition(self: *GoodShip) !vec.Vec2 {
        return self.pos;
    }
    pub fn getVelocity(self: *GoodShip) !vec.Vec2 {
        return self.vel;
    }
    pub fn setPosition(self: *GoodShip, p: vec.Vec2) !void {
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
    vel: vec.Vec2 = .{ .x = 0, .y = 0 },
    pub fn getPosition(_: *NoPositionReader) !vec.Vec2 {
        return error.UnreadablePosition;
    }
    pub fn getVelocity(self: *NoPositionReader) !vec.Vec2 {
        return self.vel;
    }
    pub fn setPosition(_: *NoPositionReader, _: vec.Vec2) !void {}
};

pub const NoVelocityReader = struct {
    pos: vec.Vec2 = .{ .x = 0, .y = 0 },
    pub fn getPosition(self: *NoVelocityReader) !vec.Vec2 {
        return self.pos;
    }
    pub fn getVelocity(_: *NoVelocityReader) !vec.Vec2 {
        return error.UnreadableVelocity;
    }
    pub fn setPosition(_: *NoVelocityReader, _: vec.Vec2) !void {}
};

pub const NoPositionWriter = struct {
    pos: vec.Vec2 = .{ .x = 0, .y = 0 },
    vel: vec.Vec2 = .{ .x = 0, .y = 0 },
    pub fn getPosition(self: *NoPositionWriter) !vec.Vec2 {
        return self.pos;
    }
    pub fn getVelocity(self: *NoPositionWriter) !vec.Vec2 {
        return self.vel;
    }
    pub fn setPosition(_: *NoPositionWriter, _: vec.Vec2) !void {
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
