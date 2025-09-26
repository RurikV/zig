// Game server microservice entry point (with JWT auth)
const std = @import("std");
const server = @import("server.zig");
const jwt = @import("jwt.zig");
const IoC = @import("commands/ioc.zig");
const core = @import("commands/core.zig");

pub fn main() !void {
    const A = std.heap.page_allocator;

    // Minimal router: map a demo operation id to a safe IoC admin op (no-op domain)
    var router = server.OpRouter.init();
    defer router.deinit(A);
    try router.put(A, "noop", "Scopes.New");

    // Init game registry
    var reg = server.GameRegistry.init(A);
    defer reg.deinit();

    // Prepare IoC current scope for the example admin op usage (not strictly required to start the server)
    const scope: []const u8 = "prod";
    var q = core.CommandQueue.init(A);
    defer q.deinit();
    (try IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&scope)), null)).call(@ptrCast(0), &q) catch {};
    (try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&scope)), null)).call(@ptrCast(0), &q) catch {};

    // Load JWT secret (env JWT_SECRET or fallback)
    const secret = jwt.defaultSecret(A);
    const secret_is_owned = secret.len != "dev-secret".len or !std.mem.eql(u8, secret, "dev-secret");
    defer if (secret_is_owned) A.free(secret);

    std.debug.print("Starting Game Server on 0.0.0.0:8080 (endpoint: POST /message with Authorization: Bearer <jwt>)\n", .{});
    try server.run_server_auth(A, &reg, &router, "0.0.0.0", secret);
}
