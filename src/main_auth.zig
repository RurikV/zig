// Authorization microservice entry point
const std = @import("std");
const auth_service = @import("auth_service.zig");

pub fn main() !void {
    const A = std.heap.page_allocator;
    std.debug.print("Starting Auth Service on 0.0.0.0:8081 (endpoints: POST /games, POST /token)\n", .{});
    try auth_service.run_auth_service(A, "0.0.0.0");
}
