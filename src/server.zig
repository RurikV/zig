const std = @import("std");
const core = @import("commands/core.zig");
const threading = @import("commands/threading.zig");
const IoC = @import("commands/ioc.zig");

const Allocator = std.mem.Allocator;

// Universal inbound message format (JSON)
// {
//   "game_id": "g1",
//   "object_id": "548",
//   "operation_id": "move_straight",
//   "args": { ... }
// }
pub const InboundMessage = struct {
    game_id: []const u8,
    object_id: []const u8,
    operation_id: []const u8,
    // keep raw args as JSON text to avoid tight coupling; specific command will parse
    args_json: []const u8,
};

pub fn free_inbound_message(a: Allocator, msg: InboundMessage) void {
    // All slices returned by parse_inbound_json are owned by the caller
    a.free(msg.game_id);
    a.free(msg.object_id);
    a.free(msg.operation_id);
    a.free(msg.args_json);
}

// Map operation_id -> IoC key (to avoid direct injection from user-provided strings)
pub const OpRouter = struct {
    // simple string hashmap mapping operation_id to IoC key
    map: std.StringHashMapUnmanaged([]const u8) = .{},

    pub fn init() OpRouter {
        return .{};
    }
    pub fn deinit(self: *OpRouter, a: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            a.free(kv.key_ptr.*);
            a.free(kv.value_ptr.*);
        }
        self.map.deinit(a);
    }
    pub fn put(self: *OpRouter, a: Allocator, op_id: []const u8, ioc_key: []const u8) !void {
        const dup = try a.dupe(u8, ioc_key);
        try self.map.put(a, try a.dupe(u8, op_id), dup);
    }
    pub fn get(self: *const OpRouter, op_id: []const u8) ?[]const u8 {
        return self.map.get(op_id);
    }
};

// Game runtime: per-game command queue worker
pub const GameRuntime = struct {
    worker: threading.Worker,

    pub fn init(a: Allocator) GameRuntime {
        const w = threading.Worker.init(a);
        return .{ .worker = w };
    }
    pub fn deinit(self: *GameRuntime) void {
        self.worker.deinit();
    }
};

// Registry of games (routing by game_id)
pub const GameRegistry = struct {
    allocator: Allocator,
    mtx: std.Thread.Mutex = .{},
    games: std.StringHashMapUnmanaged(GameRuntime) = .{},

    pub fn init(a: Allocator) GameRegistry {
        return .{ .allocator = a };
    }
    pub fn deinit(self: *GameRegistry) void {
        var it = self.games.iterator();
        while (it.next()) |kv| {
            var g = kv.value_ptr.*;
            g.deinit();
            self.allocator.free(kv.key_ptr.*);
        }
        self.games.deinit(self.allocator);
    }
    pub fn ensureGame(self: *GameRegistry, id: []const u8) !*GameRuntime {
        self.mtx.lock();
        defer self.mtx.unlock();
        if (self.games.getPtr(id)) |p| return p;
        const dup = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(dup);
        const gr = GameRuntime.init(self.allocator);
        try self.games.put(self.allocator, dup, gr);
        const p = self.games.getPtr(dup).?;
        // Do not auto-start the worker in tests; it can be started explicitly by runtime code if needed.
        return p;
    }
};

// InterpretCommand: builds domain command via IoC and enqueues it into the game queue
const InterpretCtx = struct {
    allocator: Allocator,
    registry: *GameRegistry,
    router: *const OpRouter,
    msg: InboundMessage,
};

fn execInterpret(ctx: *InterpretCtx, _: *core.CommandQueue) !void {
    // Determine IoC key by operation_id using router to avoid injection
    const key = ctx.router.get(ctx.msg.operation_id) orelse return error.UnknownOperation;
    // Prepare arguments: pass object_id and args_json as pointers
    var obj_id = ctx.msg.object_id;
    var args_json = ctx.msg.args_json;
    const cmd = try IoC.Resolve(ctx.allocator, key, @ptrCast(&obj_id), @ptrCast(&args_json));
    // Route to the game queue
    const game = try ctx.registry.ensureGame(ctx.msg.game_id);
    game.worker.enqueue(cmd);
}

pub const InterpretFactory = struct {
    fn thunk(raw: *anyopaque, q: *core.CommandQueue) anyerror!void {
        const typed: *InterpretCtx = @ptrCast(@alignCast(raw));
        return execInterpret(typed, q);
    }
    fn dropThunk(raw: *anyopaque, a: Allocator) void {
        const typed: *InterpretCtx = @ptrCast(@alignCast(raw));
        free_inbound_message(typed.allocator, typed.msg);
        a.destroy(typed);
    }
    pub fn make(a: Allocator, registry: *GameRegistry, router: *const OpRouter, msg: InboundMessage) core.Command {
        const ctx = a.create(InterpretCtx) catch @panic("OOM");
        // duplicate message fields to be owned by the command context
        const gid = a.dupe(u8, msg.game_id) catch @panic("OOM");
        const oid = a.dupe(u8, msg.object_id) catch @panic("OOM");
        const op = a.dupe(u8, msg.operation_id) catch @panic("OOM");
        const args = a.dupe(u8, msg.args_json) catch @panic("OOM");
        ctx.* = .{ .allocator = a, .registry = registry, .router = router, .msg = .{
            .game_id = gid,
            .object_id = oid,
            .operation_id = op,
            .args_json = args,
        } };
        return .{ .ctx = ctx, .call = thunk, .drop = dropThunk, .tag = .flaky, .is_wrapper = false, .is_log = false, .retry_stage = 0 };
    }
};

// HTTP endpoint (std.http.Server) that accepts POST /message with JSON body
pub fn run_server(a: Allocator, reg: *GameRegistry, router: *const OpRouter, address: []const u8) !void {
    var server = std.http.Server.init(.{ .reuse_address = true });
    defer server.deinit();

    var addr = try std.net.Address.resolveIp(address, 0);
    // default to 8080 if not provided in address
    addr.in.setPort(8080);
    try server.listen(addr);

    while (true) {
        var conn = try server.accept();
        defer conn.deinit();
        var buf_reader = std.io.bufferedReader(conn.stream.reader());
        var req = try std.http.Server.Request.init(conn, buf_reader.reader());
        defer req.deinit();
        try req.wait();
        if (req.method != .POST or !std.mem.eql(u8, req.head.target, "/message")) {
            try req.respond(.{ .status = .not_found, .reason = "Not Found" });
            continue;
        }
        // Read body
        const body = try req.reader().readAllAlloc(a, 1 << 20); // up to 1MB
        defer a.free(body);
        const parsed = try parse_inbound_json(a, body);
        defer free_inbound_message(a, parsed);
        const cmd = InterpretFactory.make(a, reg, router, parsed);
        // Enqueue interpret onto a fast local queue to avoid blocking HTTP; execute immediately
        var q = core.CommandQueue.init(a);
        defer q.deinit();
        _ = cmd.call(cmd.ctx, &q) catch |e| {
            const msg = std.fmt.allocPrint(a, "Error: {s}", .{@errorName(e)}) catch body;
            _ = req.respond(.{ .status = .bad_request, .reason = "Bad Request", .extra_headers = &.{}, .body = msg }) catch {};
            if (msg.ptr != body.ptr) a.free(msg);
            continue;
        };
        try req.respond(.{ .status = .ok, .reason = "OK" });
    }
}

// Simple JSON parser tailored to expected fields; keeps args as raw object slice
pub fn parse_inbound_json(a: Allocator, src: []const u8) !InboundMessage {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, src, .{});
    defer parsed.deinit();
    const root = parsed.value;
    const obj = root.object;
    const gid_v = obj.getPtr("game_id") orelse return error.Invalid;
    const oid_v = obj.getPtr("object_id") orelse return error.Invalid;
    const op_v = obj.getPtr("operation_id") orelse return error.Invalid;
    const args_v = obj.getPtr("args") orelse return error.Invalid;
    if (gid_v.* != .string or oid_v.* != .string or op_v.* != .string) return error.Invalid;
    const gid_s = gid_v.string;
    const oid_s = oid_v.string;
    const op_s = op_v.string;
    // Own the strings we return to avoid dangling pointers after parsed.deinit()
    const gid_owned = try a.dupe(u8, gid_s);
    const oid_owned = try a.dupe(u8, oid_s);
    const op_owned = try a.dupe(u8, op_s);
    var out: std.ArrayListUnmanaged(u8) = .{};
    defer out.deinit(a);
    try std.json.stringify(args_v.*, .{}, out.writer(a));
    const args_text = try out.toOwnedSlice(a);
    return .{ .game_id = gid_owned, .object_id = oid_owned, .operation_id = op_owned, .args_json = args_text };
}
