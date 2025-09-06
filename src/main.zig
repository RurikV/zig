// Minimal executable entry point for the project
const std = @import("std");

pub fn main() !void {
    // No-op main; logic is covered by library tests in src/root.zig
    std.debug.print("Space Battle server core loaded. Run `zig build test` to execute tests.\n", .{});
}
