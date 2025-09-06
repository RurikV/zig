const std = @import("std");
const t = @import("../utils/tests/helpers.zig");
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
    t.tprint("parse_inbound_json: valid message\n", .{});
    const json = "{\"game_id\":\"g1\",\"object_id\":\"548\",\"operation_id\":\"move\",\"args\":{\"v\":2}}";
    const msg = try server.parse_inbound_json(A, json);
    defer server.free_inbound_message(A, msg);
    try std.testing.expectEqualStrings("g1", msg.game_id);
    try std.testing.expectEqualStrings("548", msg.object_id);
    try std.testing.expectEqualStrings("move", msg.operation_id);
    try std.testing.expectEqualStrings("{\"v\":2}", msg.args_json);
    t.tprint("parse_inbound_json: OK\n", .{});
}

test "Endpoint: InterpretCommand resolves operation via IoC map and enqueues into game queue" {
    t.tprint("Interpret: mapped op enqueues into game queue\n", .{});
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

    const before = (try reg.ensureGame("g2")).worker.pendingCount();

    // Build and execute interpret command; it should resolve and enqueue without error
    const cmd = server.InterpretFactory.make(A, &reg, &router, msg);
    var q2 = core.CommandQueue.init(A);
    defer q2.deinit();
    try cmd.call(cmd.ctx, &q2);
    if (cmd.drop) |d| d(cmd.ctx, A);

    const after = (try reg.ensureGame("g2")).worker.pendingCount();
    t.tprint("Interpret: pending before={}, after={}\n", .{ before, after });
    try std.testing.expect(after == before + 1);
}


// --- Additional endpoint tests ---

test "Endpoint: parse_inbound_json invalid - missing fields" {
    t.tprint("parse_inbound_json: invalid missing fields\n", .{});
    const json = "{\"object_id\":\"x\",\"operation_id\":\"move\",\"args\":{}}";
    try std.testing.expectError(error.Invalid, server.parse_inbound_json(A, json));
    t.tprint("parse_inbound_json missing fields: OK\n", .{});
}

test "Endpoint: parse_inbound_json invalid - wrong types" {
    t.tprint("parse_inbound_json: invalid wrong types\n", .{});
    const json = "{\"game_id\":1,\"object_id\":\"x\",\"operation_id\":\"move\",\"args\":{}}";
    try std.testing.expectError(error.Invalid, server.parse_inbound_json(A, json));
    t.tprint("parse_inbound_json wrong types: OK\n", .{});
}

test "Endpoint: InterpretCommand returns UnknownOperation for unmapped op" {
    t.tprint("Interpret: unmapped operation -> UnknownOperation\n", .{});
    var reg = server.GameRegistry.init(A);
    defer reg.deinit();
    var router = server.OpRouter.init();
    defer router.deinit(A);

    const json = "{\"game_id\":\"gX\",\"object_id\":\"obj\",\"operation_id\":\"move\",\"args\":{}}";
    const msg = try server.parse_inbound_json(A, json);
    defer server.free_inbound_message(A, msg);

    const cmd = server.InterpretFactory.make(A, &reg, &router, msg);
    var q = core.CommandQueue.init(A);
    defer q.deinit();
    try std.testing.expectError(error.UnknownOperation, cmd.call(cmd.ctx, &q));
    if (cmd.drop) |d| d(cmd.ctx, A);
    t.tprint("Interpret unmapped: OK\n", .{});
}

test "Endpoint: GameRegistry routes by game_id into separate queues" {
    t.tprint("GameRegistry routing by game_id: start\n", .{});
    var reg = server.GameRegistry.init(A);
    defer reg.deinit();
    var router = server.OpRouter.init();
    defer router.deinit(A);
    try router.put(A, "move", "Scopes.New");

    const j1 = "{\"game_id\":\"ga\",\"object_id\":\"o1\",\"operation_id\":\"move\",\"args\":{}}";
    const j2 = "{\"game_id\":\"gb\",\"object_id\":\"o2\",\"operation_id\":\"move\",\"args\":{}}";
    const m1 = try server.parse_inbound_json(A, j1);
    defer server.free_inbound_message(A, m1);
    const m2 = try server.parse_inbound_json(A, j2);
    defer server.free_inbound_message(A, m2);

    const before_a = (try reg.ensureGame("ga")).worker.pendingCount();
    const before_b = (try reg.ensureGame("gb")).worker.pendingCount();

    var q = core.CommandQueue.init(A);
    defer q.deinit();

    const c1 = server.InterpretFactory.make(A, &reg, &router, m1);
    _ = c1.call(c1.ctx, &q) catch unreachable;
    if (c1.drop) |d| d(c1.ctx, A);

    const mid_a = (try reg.ensureGame("ga")).worker.pendingCount();
    const mid_b = (try reg.ensureGame("gb")).worker.pendingCount();
    t.tprint("After ga: before_a={} mid_a={} before_b={} mid_b={}\n", .{ before_a, mid_a, before_b, mid_b });
    try std.testing.expect(mid_a == before_a + 1);
    try std.testing.expect(mid_b == before_b);

    const c2 = server.InterpretFactory.make(A, &reg, &router, m2);
    _ = c2.call(c2.ctx, &q) catch unreachable;
    if (c2.drop) |d| d(c2.ctx, A);

    const after_a = (try reg.ensureGame("ga")).worker.pendingCount();
    const after_b = (try reg.ensureGame("gb")).worker.pendingCount();
    t.tprint("After gb: after_a={} after_b={}\n", .{ after_a, after_b });
    try std.testing.expect(after_a == mid_a);
    try std.testing.expect(after_b == mid_b + 1);
    t.tprint("GameRegistry routing by game_id: OK\n", .{});
}

test "Endpoint: InterpretFactory drop frees owned message safely" {
    t.tprint("InterpretFactory drop path\n", .{});
    var reg = server.GameRegistry.init(A);
    defer reg.deinit();
    var router = server.OpRouter.init();
    defer router.deinit(A);

    const json = "{\"game_id\":\"g3\",\"object_id\":\"o\",\"operation_id\":\"noop\",\"args\":{}}";
    const msg = try server.parse_inbound_json(A, json);
    defer server.free_inbound_message(A, msg);

    const cmd = server.InterpretFactory.make(A, &reg, &router, msg);
    // Do not call; just drop to exercise owned-free path
    if (cmd.drop) |d| d(cmd.ctx, A);
    t.tprint("InterpretFactory drop path: OK\n", .{});
}
