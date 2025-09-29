const std = @import("std");
const core = @import("../commands/core.zig");
const macro = @import("../commands/macro.zig");
const vec = @import("vector.zig");

pub const CollisionError = error{};

pub fn CollisionFn(comptime T: type) type {
    return fn (a: *T, b: *T) bool;
}

pub fn RecordFn(comptime T: type) type {
    // user_ctx can be null; implementation decides what to do
    return fn (a: *T, b: *T, hit: bool, user_ctx: ?*anyopaque) void;
}

const CellCoord = struct {
    i: i64,
    j: i64,
    pub fn fromPos(p: vec.Vec2, cell_size: f64, offset: vec.Vec2) CellCoord {
        const x = (p.x - offset.x) / cell_size;
        const y = (p.y - offset.y) / cell_size;
        // floor to i64
        const xi: i64 = @intFromFloat(std.math.floor(x));
        const yi: i64 = @intFromFloat(std.math.floor(y));
        return .{ .i = xi, .j = yi };
    }
    pub fn eql(a: CellCoord, b: CellCoord) bool {
        return a.i == b.i and a.j == b.j;
    }
};

// Stores neighbor lists by cell and remembers last cell for each object
pub fn NeighborhoodSystem(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        cell_size: f64,
        offset: vec.Vec2,
        by_cell: std.AutoHashMap(CellCoord, std.ArrayListUnmanaged(*T)),
        last_cell: std.AutoHashMap(*T, CellCoord),

        pub fn init(a: std.mem.Allocator, cell_size: f64, offset: vec.Vec2) Self {
            return .{ .allocator = a, .cell_size = cell_size, .offset = offset, .by_cell = std.AutoHashMap(CellCoord, std.ArrayListUnmanaged(*T)).init(a), .last_cell = std.AutoHashMap(*T, CellCoord).init(a) };
        }
        pub fn deinit(self: *Self) void {
            var it = self.by_cell.iterator();
            while (it.next()) |kv| kv.value_ptr.*.deinit(self.allocator);
            self.by_cell.deinit();
            self.last_cell.deinit();
        }

        fn getOrCreateCell(self: *Self, key: CellCoord) !*std.ArrayListUnmanaged(*T) {
            if (self.by_cell.getPtr(key)) |p| return p;
            try self.by_cell.put(key, .{});
            return self.by_cell.getPtr(key).?;
        }

        pub fn addObject(self: *Self, obj: *T) !void {
            const p = try obj.getPosition();
            const c = CellCoord.fromPos(p, self.cell_size, self.offset);
            var list = try self.getOrCreateCell(c);
            try list.append(self.allocator, obj);
            try self.last_cell.put(obj, c);
        }

        pub fn removeObject(self: *Self, obj: *T) void {
            if (self.last_cell.get(obj)) |oldc| {
                if (self.by_cell.getPtr(oldc)) |list| {
                    var i: usize = 0;
                    while (i < list.items.len) : (i += 1) {
                        if (list.items[i] == obj) {
                            _ = list.orderedRemove(i);
                            break;
                        }
                    }
                }
                _ = self.last_cell.remove(obj);
            }
        }

        // Update cell membership for obj and return the neighbor slice pointer for the new cell
        pub fn updateMembership(self: *Self, obj: *T) ![]*T {
            const p = try obj.getPosition();
            const newc = CellCoord.fromPos(p, self.cell_size, self.offset);
            const oldc_opt = self.last_cell.get(obj);
            if (oldc_opt) |oldc| {
                if (!CellCoord.eql(oldc, newc)) {
                    // move between lists
                    if (self.by_cell.getPtr(oldc)) |old_list| {
                        var i: usize = 0;
                        while (i < old_list.items.len) : (i += 1) {
                            if (old_list.items[i] == obj) {
                                _ = old_list.orderedRemove(i);
                                break;
                            }
                        }
                    }
                    var new_list = try self.getOrCreateCell(newc);
                    try new_list.append(self.allocator, obj);
                    try self.last_cell.put(obj, newc);
                }
            } else {
                // first time seen
                var list = try self.getOrCreateCell(newc);
                try list.append(self.allocator, obj);
                try self.last_cell.put(obj, newc);
            }
            // return slice of objects for current cell
            const curc = self.last_cell.get(obj).?;
            const cur = self.by_cell.getPtr(curc).?;
            return cur.items;
        }
    };
}

// Command to check a single pair and record using callbacks
pub fn PairCheckCtx(comptime T: type) type {
    return struct {
        a: *T,
        b: *T,
        check: *const CollisionFn(T),
        record: *const RecordFn(T),
        user_ctx: ?*anyopaque = null,
    };
}

pub fn execPairCheck(comptime T: type, ctx: *PairCheckCtx(T), _: *core.CommandQueue) anyerror!void {
    const hit = ctx.check(ctx.a, ctx.b);
    ctx.record(ctx.a, ctx.b, hit, ctx.user_ctx);
}

// Build macro of checks for obj against all others in same cell (skipping self)
pub fn buildCellMacro(
    comptime T: type,
    allocator: std.mem.Allocator,
    obj: *T,
    neighbors: []*T,
    check: *const CollisionFn(T),
    record: *const RecordFn(T),
    user_ctx: ?*anyopaque,
) !core.Command {
    // create commands for each neighbor except self
    var items = std.ArrayListUnmanaged(core.Command){};
    errdefer items.deinit(allocator);

    const Exec = struct {
        fn run(ctx: *PairCheckCtx(T), q: *core.CommandQueue) anyerror!void {
            return execPairCheck(T, ctx, q);
        }
    }.run;
    const Maker = core.CommandFactory(PairCheckCtx(T), Exec);

    for (neighbors) |other| {
        if (other == obj) continue;
        const c = try allocator.create(PairCheckCtx(T));
        c.* = .{ .a = obj, .b = other, .check = check, .record = record, .user_ctx = user_ctx };
        const cmd = Maker.makeOwned(c, .flaky, false, false);
        try items.append(allocator, cmd);
    }

    // Build an owned macro with custom drop that frees inner commands and slice
    const CollMacroCtx = struct {
        allocator: std.mem.Allocator,
        items: []const core.Command,
    };
    const collThunk = struct {
        fn call(raw: *anyopaque, q: *core.CommandQueue) anyerror!void {
            const ctx: *CollMacroCtx = @ptrCast(@alignCast(raw));
            // Execute like macro.execMacro
            for (ctx.items) |c| {
                try c.call(c.ctx, q);
            }
        }
    }.call;
    const collDrop = struct {
        fn drop(raw: *anyopaque, a: std.mem.Allocator) void {
            const ctx: *CollMacroCtx = @ptrCast(@alignCast(raw));
            // Drop inner commands then free the slice
            for (ctx.items) |c| {
                if (c.drop) |d| d(c.ctx, a);
            }
            a.free(ctx.items);
            a.destroy(ctx);
        }
    }.drop;

    const mctx = try allocator.create(CollMacroCtx);
    mctx.* = .{ .allocator = allocator, .items = try items.toOwnedSlice(allocator) };
    return .{ .ctx = mctx, .call = collThunk, .drop = collDrop, .tag = .flaky, .is_wrapper = false, .is_log = false, .retry_stage = 0 };
}

// Chain of responsibility over an arbitrary number of neighborhood systems
pub fn NeighborhoodChain(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        systems: []NeighborhoodSystem(T),

        pub fn init(a: std.mem.Allocator, systems: []NeighborhoodSystem(T)) Self {
            return .{ .allocator = a, .systems = systems };
        }
    };
}

// Update command ctx: for a moving object, update membership across all systems and place macros into given bridges
pub fn UpdateCtx(comptime T: type) type {
    return struct {
        chain: *NeighborhoodChain(T),
        obj: *T,
        // One BridgeCtx per system to be updated (length must equal chain.systems.len)
        bridges: []*macro.BridgeCtx,
        check: *const CollisionFn(T),
        record: *const RecordFn(T),
        user_ctx: ?*anyopaque = null,
    };
}

pub fn execUpdate(comptime T: type, ctx: *UpdateCtx(T), q: *core.CommandQueue) anyerror!void {
    _ = q;
    const n = ctx.chain.systems.len;
    std.debug.assert(n == ctx.bridges.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var sys_ptr: *NeighborhoodSystem(T) = &ctx.chain.systems[i];
        const neighbors = try sys_ptr.updateMembership(ctx.obj);
        // build macro and store into bridge.inner (replace previous)
        const new_macro = try buildCellMacro(T, ctx.chain.allocator, ctx.obj, neighbors, ctx.check, ctx.record, ctx.user_ctx);
        var br = ctx.bridges[i];
        // drop previous command if owned
        if (br.inner.drop) |d| d(br.inner.ctx, ctx.chain.allocator);
        br.inner = new_macro;
    }
}
