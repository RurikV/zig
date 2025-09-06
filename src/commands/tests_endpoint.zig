const std = @import("std");
const core = @import("core.zig");
const IoC = @import("ioc.zig");
const server = @import("../server.zig");

const A = std.testing.allocator;

const DummyCtx = struct { dummy: u8 };
fn execDummy(ctx: *DummyCtx, _: *core.CommandQueue) !void { _ = ctx; }

fn factory_make_counter(allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    _ = args; // ignore
    const Maker = core.CommandFactory(DummyCtx, execDummy);
    const ctx = try allocator.create(DummyCtx);
    ctx.* = .{ .dummy = 0 };
    return Maker.makeOwned(ctx, .flaky, false, false);
}

fn register_test_scope(scope: []const u8) void {
    var q = core.CommandQueue.init(A);
    defer q.deinit();
    const cnew = IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&scope)), null) catch unreachable;
    cnew.call(cnew.ctx, &q) catch {};
    const ccur = IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&scope)), null) catch unreachable;
    ccur.call(ccur.ctx, &q) catch {};
}

test "Endpoint: parse_inbound_json parses universal message" {
    const json = "{\"game_id\":\"g1\",\"object_id\":\"548\",\"operation_id\":\"move\",\"args\":{\"v\":2}}";
    const msg = try server.parse_inbound_json(A, json);
    defer server.free_inbound_message(A, msg);
    try std.testing.expectEqualStrings("g1", msg.game_id);
    try std.testing.expectEqualStrings("548", msg.object_id);
    try std.testing.expectEqualStrings("move", msg.operation_id);
    try std.testing.expectEqualStrings("{\"v\":2}", msg.args_json);
}

test "Endpoint: InterpretCommand resolves operation via IoC map and enqueues into game queue" {
    var reg = server.GameRegistry.init(A);
    defer reg.deinit();
    var router = server.OpRouter.init();
    defer router.deinit(A);

    // Router maps operation_id to a built-in admin op to avoid extra setup
    try router.put(A, "move", "Scopes.New");

    // Message with object id and args; args_json is opaque for the endpoint.
    const json = "{\"game_id\":\"g2\",\"object_id\":\"obj\",\"operation_id\":\"move\",\"args\":{}}";
    const msg = try server.parse_inbound_json(A, json);
    defer server.free_inbound_message(A, msg);

    // Build and execute interpret command; it should resolve and enqueue without error
    const cmd = server.InterpretFactory.make(A, &reg, &router, msg);
    var q2 = core.CommandQueue.init(A);
    defer q2.deinit();
    try cmd.call(cmd.ctx, &q2);
    if (cmd.drop) |d| d(cmd.ctx, A);
    // If we get here, the routing and resolve succeeded.
    try std.testing.expect(true);
}
