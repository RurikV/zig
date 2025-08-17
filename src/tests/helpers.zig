const std = @import("std");

pub fn tprint(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[TEST] " ++ fmt, args);
}
