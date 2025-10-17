const std = @import("std");
const testing = std.testing;
const t = @import("../utils/tests/helpers.zig");
const vec = @import("vector.zig");
const core = @import("../commands/core.zig");
const macro = @import("../commands/macro.zig");
const coll = @import("collision.zig");

const CommandFactory = core.CommandFactory;

// Simple object used in tests
const Obj = struct {
    pos: vec.Vec2,
    pub fn getPosition(self: *Obj) !vec.Vec2 {
        return self.pos;
    }
};

// Recorder for counting performed checks when predicate passes
const Recorder = struct { count: usize = 0 };

fn alwaysTrue(_: *Obj, _: *Obj) bool {
    return true;
}

fn recordCount(_: *Obj, _: *Obj, hit: bool, user_ctx: ?*anyopaque) void {
    if (!hit) return;
    const pr: *Recorder = @ptrCast(@alignCast(user_ctx.?));
    pr.count += 1;
}

fn execUpdate_O(ctx: *coll.UpdateCtx(Obj), q: *core.CommandQueue) anyerror!void {
    return coll.execUpdate(Obj, ctx, q);
}

fn execBridge(ctx: *macro.BridgeCtx, q: *core.CommandQueue) anyerror!void {
    return macro.execBridge(ctx, q);
}

test "Collision: single system list formation and macro creation" {
    t.tprint("Collision test: single system membership and macro\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    // objects
    var o1 = Obj{ .pos = .{ .x = 1, .y = 1 } }; // moving
    var o2 = Obj{ .pos = .{ .x = 2, .y = 2 } }; // same cell
    var o3 = Obj{ .pos = .{ .x = 15, .y = 0 } }; // different cell

    // systems
    var systems = [_]coll.NeighborhoodSystem(Obj){coll.NeighborhoodSystem(Obj).init(A, 10, .{ .x = 0, .y = 0 })};
    defer systems[0].deinit();

    // add static objects to system 0
    try systems[0].addObject(&o2);
    try systems[0].addObject(&o3);

    var chain = coll.NeighborhoodChain(Obj).init(A, systems[0..]);

    // prepare a bridge for this system
    var noop = macro.NoOpCtx{};
    var bridge = macro.BridgeCtx{ .inner = CommandFactory(macro.NoOpCtx, macro.execNoOp).make(&noop, .flaky) };
    var bridges = [_]*macro.BridgeCtx{&bridge};

    var rec = Recorder{ .count = 0 };

    // Build update command ctx
    var uctx = coll.UpdateCtx(Obj){ .chain = &chain, .obj = &o1, .bridges = bridges[0..], .check = &alwaysTrue, .record = &recordCount, .user_ctx = &rec };
    const UM = CommandFactory(coll.UpdateCtx(Obj), execUpdate_O);
    var ucmd = UM.make(&uctx, .flaky);

    var q = core.CommandQueue.init(A);
    defer q.deinit();

    try ucmd.call(ucmd.ctx, &q);

    // Execute bridge: should perform 1 check with o2
    const BM = CommandFactory(macro.BridgeCtx, execBridge);
    const bcmd = BM.make(&bridge, .flaky);
    try bcmd.call(bcmd.ctx, &q);

    try testing.expectEqual(@as(usize, 1), rec.count);

    // Move o1 to new cell with o3 and update again
    o1.pos = .{ .x = 16, .y = 0 };
    rec.count = 0;
    try ucmd.call(ucmd.ctx, &q);
    try bcmd.call(bcmd.ctx, &q);
    try testing.expectEqual(@as(usize, 1), rec.count);

    // cleanup: drop bridge's inner macro
    if (bridge.inner.drop) |d| d(bridge.inner.ctx, A);
}

// Boundary test with two offset systems
fn execUpdate2_O(ctx: *coll.UpdateCtx(Obj), q: *core.CommandQueue) anyerror!void {
    return coll.execUpdate(Obj, ctx, q);
}

test "Collision: dual offset systems cover boundary case" {
    t.tprint("Collision test: dual systems boundary coverage\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    // objects
    var a = Obj{ .pos = .{ .x = 9.1, .y = 0 } }; // moving near boundary
    var b = Obj{ .pos = .{ .x = 10.2, .y = 0 } }; // on the other side

    var systems = [_]coll.NeighborhoodSystem(Obj){
        coll.NeighborhoodSystem(Obj).init(A, 10, .{ .x = 0, .y = 0 }),
        coll.NeighborhoodSystem(Obj).init(A, 10, .{ .x = 5, .y = 5 }),
    };
    defer {
        systems[0].deinit();
        systems[1].deinit();
    }

    // add static b to both systems
    try systems[0].addObject(&b);
    try systems[1].addObject(&b);

    var chain = coll.NeighborhoodChain(Obj).init(A, systems[0..]);

    // two bridges
    var noop0 = macro.NoOpCtx{};
    var noop1 = macro.NoOpCtx{};
    var bridge0 = macro.BridgeCtx{ .inner = CommandFactory(macro.NoOpCtx, macro.execNoOp).make(&noop0, .flaky) };
    var bridge1 = macro.BridgeCtx{ .inner = CommandFactory(macro.NoOpCtx, macro.execNoOp).make(&noop1, .flaky) };
    var bridges = [_]*macro.BridgeCtx{ &bridge0, &bridge1 };

    var rec = Recorder{ .count = 0 };

    var uctx = coll.UpdateCtx(Obj){ .chain = &chain, .obj = &a, .bridges = bridges[0..], .check = &alwaysTrue, .record = &recordCount, .user_ctx = &rec };
    const UM = CommandFactory(coll.UpdateCtx(Obj), execUpdate2_O);
    var ucmd = UM.make(&uctx, .flaky);

    var q = core.CommandQueue.init(A);
    defer q.deinit();

    try ucmd.call(ucmd.ctx, &q);

    // Execute bridge for system 0: should be 0 checks (different cells)
    const BM = CommandFactory(macro.BridgeCtx, execBridge);
    const b0 = BM.make(&bridge0, .flaky);
    rec.count = 0;
    try b0.call(b0.ctx, &q);
    try testing.expectEqual(@as(usize, 0), rec.count);

    // Execute bridge for system 1: should be 1 check (same shifted cell)
    const b1 = BM.make(&bridge1, .flaky);
    rec.count = 0;
    try b1.call(b1.ctx, &q);
    try testing.expectEqual(@as(usize, 1), rec.count);

    // cleanup
    if (bridge0.inner.drop) |d| d(bridge0.inner.ctx, A);
    if (bridge1.inner.drop) |d| d(bridge1.inner.ctx, A);
}

fn predNegX(_: *Obj, b: *Obj) bool {
    return b.pos.x < 0;
}

const HM = struct { total: usize = 0, misses: usize = 0 };
fn recordHM(_: *Obj, _: *Obj, hit: bool, user_ctx: ?*anyopaque) void {
    const pr: *HM = @ptrCast(@alignCast(user_ctx.?));
    pr.total += 1;
    if (!hit) pr.misses += 1;
}

test "Collision: buildCellMacro skips self and respects predicate" {
    t.tprint("Collision test: buildCellMacro skip self + predicate\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var obj = Obj{ .pos = .{ .x = 0, .y = 0 } };
    var n1 = Obj{ .pos = .{ .x = -1, .y = 0 } }; // hit (neg x)
    var n2 = Obj{ .pos = .{ .x = 1, .y = 0 } }; // miss

    var neighbors = [_]*Obj{ &obj, &n1, &n2 };

    var rec = Recorder{ .count = 0 };
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    const cmd = try coll.buildCellMacro(Obj, A, &obj, neighbors[0..], &predNegX, &recordCount, &rec);
    defer if (cmd.drop) |d| d(cmd.ctx, A);
    try cmd.call(cmd.ctx, &q);

    try testing.expectEqual(@as(usize, 1), rec.count);
}

test "Collision: macro with only self does nothing" {
    t.tprint("Collision test: macro with only self\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var obj = Obj{ .pos = .{ .x = 0, .y = 0 } };
    var neighbors = [_]*Obj{&obj};

    var rec = Recorder{ .count = 0 };
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    const cmd = try coll.buildCellMacro(Obj, A, &obj, neighbors[0..], &alwaysTrue, &recordCount, &rec);
    defer if (cmd.drop) |d| d(cmd.ctx, A);
    try cmd.call(cmd.ctx, &q);

    try testing.expectEqual(@as(usize, 0), rec.count);
}

test "Collision: removeObject reduces neighbor checks and same-cell update persists" {
    t.tprint("Collision test: removeObject + same-cell update\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var a = Obj{ .pos = .{ .x = 1, .y = 1 } };
    var b = Obj{ .pos = .{ .x = 2, .y = 2 } };
    var c = Obj{ .pos = .{ .x = 3, .y = 3 } };

    var sys = coll.NeighborhoodSystem(Obj).init(A, 10, .{ .x = 0, .y = 0 });
    defer sys.deinit();
    try sys.addObject(&b);
    try sys.addObject(&c);

    var systems = [_]coll.NeighborhoodSystem(Obj){sys};
    var chain = coll.NeighborhoodChain(Obj).init(A, systems[0..]);

    var noop = macro.NoOpCtx{};
    var bridge = macro.BridgeCtx{ .inner = CommandFactory(macro.NoOpCtx, macro.execNoOp).make(&noop, .flaky) };
    var bridges = [_]*macro.BridgeCtx{&bridge};

    var rec = Recorder{ .count = 0 };
    var uctx = coll.UpdateCtx(Obj){ .chain = &chain, .obj = &a, .bridges = bridges[0..], .check = &alwaysTrue, .record = &recordCount, .user_ctx = &rec };
    const UM = CommandFactory(coll.UpdateCtx(Obj), execUpdate_O);
    var ucmd = UM.make(&uctx, .flaky);

    var q = core.CommandQueue.init(A);
    defer q.deinit();

    // Initial: 2 neighbors
    try ucmd.call(ucmd.ctx, &q);
    const BM = CommandFactory(macro.BridgeCtx, execBridge);
    const bcmd = BM.make(&bridge, .flaky);
    try bcmd.call(bcmd.ctx, &q);
    try testing.expectEqual(@as(usize, 2), rec.count);

    // Remove one neighbor and update again
    rec.count = 0;
    sys.removeObject(&c);
    try ucmd.call(ucmd.ctx, &q);
    try bcmd.call(bcmd.ctx, &q);
    try testing.expectEqual(@as(usize, 1), rec.count);

    // Move within same cell; still 1 neighbor
    rec.count = 0;
    a.pos = .{ .x = 1.5, .y = 1.5 };
    try ucmd.call(ucmd.ctx, &q);
    try bcmd.call(bcmd.ctx, &q);
    try testing.expectEqual(@as(usize, 1), rec.count);

    if (bridge.inner.drop) |d| d(bridge.inner.ctx, A);
}

test "Collision: negative coordinates with shifted offset" {
    t.tprint("Collision test: negative coords + shifted offset\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var a = Obj{ .pos = .{ .x = -1, .y = 0 } };
    var b = Obj{ .pos = .{ .x = 3, .y = 0 } };

    var systems = [_]coll.NeighborhoodSystem(Obj){
        coll.NeighborhoodSystem(Obj).init(A, 10, .{ .x = 0, .y = 0 }),
        coll.NeighborhoodSystem(Obj).init(A, 10, .{ .x = 5, .y = 5 }),
    };
    defer {
        systems[0].deinit();
        systems[1].deinit();
    }

    try systems[0].addObject(&b);
    try systems[1].addObject(&b);

    var chain = coll.NeighborhoodChain(Obj).init(A, systems[0..]);

    var noop0 = macro.NoOpCtx{};
    var noop1 = macro.NoOpCtx{};
    var bridge0 = macro.BridgeCtx{ .inner = CommandFactory(macro.NoOpCtx, macro.execNoOp).make(&noop0, .flaky) };
    var bridge1 = macro.BridgeCtx{ .inner = CommandFactory(macro.NoOpCtx, macro.execNoOp).make(&noop1, .flaky) };
    var bridges = [_]*macro.BridgeCtx{ &bridge0, &bridge1 };

    var rec = Recorder{ .count = 0 };
    var uctx = coll.UpdateCtx(Obj){ .chain = &chain, .obj = &a, .bridges = bridges[0..], .check = &alwaysTrue, .record = &recordCount, .user_ctx = &rec };
    const UM = CommandFactory(coll.UpdateCtx(Obj), execUpdate2_O);
    var ucmd = UM.make(&uctx, .flaky);

    var q = core.CommandQueue.init(A);
    defer q.deinit();

    try ucmd.call(ucmd.ctx, &q);

    const BM = CommandFactory(macro.BridgeCtx, execBridge);
    const b0 = BM.make(&bridge0, .flaky);
    const b1 = BM.make(&bridge1, .flaky);

    rec.count = 0;
    try b0.call(b0.ctx, &q);
    try testing.expectEqual(@as(usize, 0), rec.count);

    rec.count = 0;
    try b1.call(b1.ctx, &q);
    try testing.expectEqual(@as(usize, 1), rec.count);

    if (bridge0.inner.drop) |d| d(bridge0.inner.ctx, A);
    if (bridge1.inner.drop) |d| d(bridge1.inner.ctx, A);
}

test "Collision: record is invoked on miss (hit=false)" {
    t.tprint("Collision test: record miss path\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var obj = Obj{ .pos = .{ .x = 0, .y = 0 } };
    var n = Obj{ .pos = .{ .x = 1, .y = 0 } }; // not negative

    var neighbors = [_]*Obj{ &obj, &n };

    var hm = HM{ .total = 0, .misses = 0 };
    var q = core.CommandQueue.init(A);
    defer q.deinit();

    const cmd = try coll.buildCellMacro(Obj, A, &obj, neighbors[0..], &predNegX, &recordHM, &hm);
    defer if (cmd.drop) |d| d(cmd.ctx, A);
    try cmd.call(cmd.ctx, &q);

    try testing.expectEqual(@as(usize, 1), hm.total);
    try testing.expectEqual(@as(usize, 1), hm.misses);
}
