//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // Print guidance message to stderr to avoid std.io API incompatibilities on Zig master.
    std.debug.print("Run `zig build test` to run the tests.\n", .{});
}

test "simple test" {
    std.debug.print("[TEST] Running simple test...\n", .{});
    const value: i32 = 42;
    try std.testing.expectEqual(@as(i32, 42), value);
    std.debug.print("[TEST] Simple test passed!\n", .{});
}

test "use other module" {
    std.debug.print("[TEST] Running module test...\n", .{});
    try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
    std.debug.print("[TEST] Module test passed!\n", .{});
}

test "fuzz example" {
    std.debug.print("[TEST] Running fuzz test...\n", .{});
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
    std.debug.print("[TEST] Fuzz test passed!\n", .{});
}

const std = @import("std");

/// This imports the separate module containing `root.zig`. Take a look in `build.zig` for details.
const lib = @import("zig_lib");
