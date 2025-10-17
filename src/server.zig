const std = @import("std");
const core = @import("commands/core.zig");
const threading = @import("commands/threading.zig");
const IoC = @import("commands/ioc.zig");
const jwt = @import("jwt.zig");

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

// Game runtime: per-game command queue worker + ownership registry
pub const GameRuntime = struct {
    allocator: Allocator,
    worker: threading.Worker,
    owners: std.StringHashMapUnmanaged([]u8) = .{},

    pub fn init(a: Allocator) GameRuntime {
        const w = threading.Worker.init(a);
        return .{ .allocator = a, .worker = w, .owners = .{} };
    }
    pub fn deinit(self: *GameRuntime) void {
        self.worker.deinit();
        var it = self.owners.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.*);
        }
        self.owners.deinit(self.allocator);
    }
    pub fn setOwner(self: *GameRuntime, object_id: []const u8, user: []const u8) !void {
        if (self.owners.getPtr(object_id)) |p| {
            // replace existing owner value
            self.allocator.free(p.*);
            p.* = try self.allocator.dupe(u8, user);
            return;
        }
        const k = try self.allocator.dupe(u8, object_id);
        errdefer self.allocator.free(k);
        const v = try self.allocator.dupe(u8, user);
        errdefer self.allocator.free(v);
        try self.owners.put(self.allocator, k, v);
    }
    pub fn getOwner(self: *GameRuntime, object_id: []const u8) ?[]const u8 {
        return self.owners.get(object_id);
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

    pub fn setOwner(self: *GameRegistry, game_id: []const u8, object_id: []const u8, user: []const u8) !void {
        const g = try self.ensureGame(game_id);
        try g.setOwner(object_id, user);
    }

    pub fn getOwner(self: *GameRegistry, game_id: []const u8, object_id: []const u8) ?[]const u8 {
        self.mtx.lock();
        defer self.mtx.unlock();
        const gp = self.games.getPtr(game_id) orelse return null;
        return gp.getOwner(object_id);
    }
};

// InterpretCommand: builds domain command via IoC and enqueues it into the game queue
const InterpretCtx = struct {
    allocator: Allocator,
    registry: *GameRegistry,
    router: *const OpRouter,
    msg: InboundMessage,
    user: ?[]const u8 = null,
};

fn execInterpret(ctx: *InterpretCtx, _: *core.CommandQueue) !void {
    // Determine IoC key by operation_id using router to avoid injection
    const key = ctx.router.get(ctx.msg.operation_id) orelse return error.UnknownOperation;

    // If user is provided, switch to per-player scope under this game
    if (ctx.user) |u| {
        const scope_name = try std.fmt.allocPrint(ctx.allocator, "game:{s}|user:{s}", .{ ctx.msg.game_id, u });
        defer ctx.allocator.free(scope_name);
        var sn = scope_name;
        var qtmp = core.CommandQueue.init(ctx.allocator);
        defer qtmp.deinit();
        const cnew = try IoC.Resolve(ctx.allocator, "Scopes.New", @ptrCast(&sn), null);
        _ = cnew.call(cnew.ctx, &qtmp) catch {};
        if (cnew.drop) |d| d(cnew.ctx, ctx.allocator);
        const ccur = try IoC.Resolve(ctx.allocator, "Scopes.Current", @ptrCast(&sn), null);
        _ = ccur.call(ccur.ctx, &qtmp) catch {};
        if (ccur.drop) |d2| d2(ccur.ctx, ctx.allocator);
    }

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
        if (typed.user) |u| a.free(u);
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
    pub fn makeWithUser(a: Allocator, registry: *GameRegistry, router: *const OpRouter, msg: InboundMessage, user: []const u8) core.Command {
        const ctx = a.create(InterpretCtx) catch @panic("OOM");
        const gid = a.dupe(u8, msg.game_id) catch @panic("OOM");
        const oid = a.dupe(u8, msg.object_id) catch @panic("OOM");
        const op = a.dupe(u8, msg.operation_id) catch @panic("OOM");
        const args = a.dupe(u8, msg.args_json) catch @panic("OOM");
        const usr = a.dupe(u8, user) catch @panic("OOM");
        ctx.* = .{ .allocator = a, .registry = registry, .router = router, .msg = .{
            .game_id = gid,
            .object_id = oid,
            .operation_id = op,
            .args_json = args,
        }, .user = usr };
        return .{ .ctx = ctx, .call = thunk, .drop = dropThunk, .tag = .flaky, .is_wrapper = false, .is_log = false, .retry_stage = 0 };
    }
};

// HTTP endpoint (std.http.Server) that accepts POST /message with JSON body
pub fn run_server(a: Allocator, reg: *GameRegistry, router: *const OpRouter, address: []const u8) !void {
    // Minimal HTTP/1.1 loop using TCP sockets for Zig version compatibility
    const addr = try std.net.Address.resolveIp(address, 8080);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    while (true) {
        var conn = try listener.accept();
        defer conn.stream.close();
        var reader = struct {
            s: *std.net.Stream,
            fn read(self: *@This(), buf: []u8) !usize {
                return self.s.read(buf);
            }
        }{ .s = &conn.stream };
        var writer = struct {
            s: *std.net.Stream,
            a: Allocator,
            fn writeAll(self: *@This(), data: []const u8) !void {
                var off: usize = 0;
                while (off < data.len) {
                    const n = try self.s.write(data[off..]);
                    if (n == 0) break;
                    off += n;
                }
            }
            fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
                const buf = try std.fmt.allocPrint(self.a, fmt, args);
                defer self.a.free(buf);
                try self.writeAll(buf);
            }
        }{ .s = &conn.stream, .a = a };

        // Read headers and body into buffer
        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(a);
        var tmp: [4096]u8 = undefined;
        var head_end: ?usize = null;
        while (true) {
            const n = try reader.read(&tmp);
            if (n == 0) break;
            try buf.appendSlice(a, tmp[0..n]);
            if (head_end == null) {
                if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |pos| head_end = pos + 4 else continue;
            }
            // compute content-length
            var cl: usize = 0;
            var it = std.mem.splitSequence(u8, buf.items[0..head_end.?], "\r\n");
            _ = it.next();
            while (it.next()) |line| {
                if (line.len == 0) break;
                if (std.mem.startsWith(u8, line, "Content-Length:")) {
                    cl = std.fmt.parseInt(usize, std.mem.trim(u8, line["Content-Length:".len..], " "), 10) catch 0;
                }
            }
            const have = buf.items.len - head_end.?;
            if (have >= cl) break;
        }

        const he = head_end orelse buf.items.len;
        const head = buf.items[0..he];
        // Parse request line
        var it = std.mem.splitSequence(u8, head, "\r\n");
        const req_line = it.next() orelse "";
        var it2 = std.mem.splitScalar(u8, req_line, ' ');
        const method = it2.next() orelse "";
        const target = it2.next() orelse "";

        if (!std.mem.eql(u8, method, "POST") or !std.mem.eql(u8, target, "/message")) {
            try writer.print("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
            continue;
        }

        // Determine body
        var cl: usize = 0;
        var hscan = std.mem.splitSequence(u8, head, "\r\n");
        _ = hscan.next();
        while (hscan.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "Content-Length:")) {
                cl = std.fmt.parseInt(usize, std.mem.trim(u8, line["Content-Length:".len..], " "), 10) catch 0;
            }
        }
        const body = if (he + cl <= buf.items.len) buf.items[he .. he + cl] else buf.items[he..];

        const parsed = parse_inbound_json(a, body) catch |e| {
            const msg = std.fmt.allocPrint(a, "Error: {s}", .{@errorName(e)}) catch body;
            try writer.print("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
            try writer.writeAll(msg);
            if (msg.ptr != body.ptr) a.free(msg);
            continue;
        };
        defer free_inbound_message(a, parsed);

        const cmd = InterpretFactory.make(a, reg, router, parsed);
        var q = core.CommandQueue.init(a);
        defer q.deinit();
        _ = cmd.call(cmd.ctx, &q) catch |e| {
            const msg = std.fmt.allocPrint(a, "Error: {s}", .{@errorName(e)}) catch body;
            try writer.print("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
            try writer.writeAll(msg);
            if (msg.ptr != body.ptr) a.free(msg);
            continue;
        };
        try writer.print("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
    }
}

// Simple JSON serializer for std.json.Value to ensure cross-version stability
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn writeJsonValue(w: anytype, v: std.json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{}", .{i});
            try w.writeAll(s);
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{}", .{f});
            try w.writeAll(s);
        },
        .number_string => |ns| try w.writeAll(ns),
        .string => |s| try writeJsonString(w, s),
        .array => |arr| {
            try w.writeByte('[');
            var first = true;
            for (arr.items) |item| {
                if (!first) try w.writeByte(',');
                first = false;
                try writeJsonValue(w, item);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                try writeJsonString(w, entry.key_ptr.*);
                try w.writeByte(':');
                try writeJsonValue(w, entry.value_ptr.*);
            }
            try w.writeByte('}');
        },
    }
}

const ListWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    pub fn writeAll(self: *ListWriter, data: []const u8) !void {
        try self.list.appendSlice(self.allocator, data);
    }
    pub fn writeByte(self: *ListWriter, b: u8) !void {
        try self.list.append(self.allocator, b);
    }
};

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
    errdefer a.free(gid_owned);
    const oid_owned = try a.dupe(u8, oid_s);
    errdefer a.free(oid_owned);
    const op_owned = try a.dupe(u8, op_s);
    errdefer a.free(op_owned);

    // Build args JSON deterministically using local serializer (compact, no spaces)
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(a);
    var lw = ListWriter{ .list = &out, .allocator = a };
    try writeJsonValue(&lw, args_v.*);
    const args_text = try out.toOwnedSlice(a);
    return .{ .game_id = gid_owned, .object_id = oid_owned, .operation_id = op_owned, .args_json = args_text };
}

// Authorization: verify JWT token against inbound message's game_id. Returns subject (user) on success.
pub const AuthzError = error{ InvalidToken, Forbidden };

pub fn verifyJwtForMessage(a: Allocator, secret: []const u8, token: []const u8, msg: InboundMessage) ![]u8 {
    const claims = jwt.verifyHS256(a, secret, token) catch |e| {
        switch (e) {
            jwt.VerifyError.InvalidToken, jwt.VerifyError.InvalidJson, jwt.VerifyError.InvalidAlg, jwt.VerifyError.SignatureMismatch => return AuthzError.InvalidToken,
            else => return AuthzError.InvalidToken,
        }
    };
    defer jwt.freeClaims(a, claims);
    if (!std.mem.eql(u8, claims.game_id, msg.game_id)) return AuthzError.Forbidden;
    return try a.dupe(u8, claims.sub);
}

// Ownership authorization: if object has an owner, only that user may control it
pub fn authorizeOwnership(reg: *GameRegistry, msg: InboundMessage, user: []const u8) AuthzError!void {
    if (reg.getOwner(msg.game_id, msg.object_id)) |o| {
        if (!std.mem.eql(u8, o, user)) return AuthzError.Forbidden;
    }
}

// HTTP endpoint with JWT auth (expects Authorization: Bearer <token>)
pub fn run_server_auth(a: Allocator, reg: *GameRegistry, router: *const OpRouter, address: []const u8, secret: []const u8) !void {
    // Minimal HTTP/1.1 loop with Authorization: Bearer <jwt>
    const addr = try std.net.Address.resolveIp(address, 8080);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    while (true) {
        var conn = try listener.accept();
        defer conn.stream.close();
        var reader = struct {
            s: *std.net.Stream,
            fn read(self: *@This(), buf: []u8) !usize {
                return self.s.read(buf);
            }
        }{ .s = &conn.stream };
        var writer = struct {
            s: *std.net.Stream,
            a: Allocator,
            fn writeAll(self: *@This(), data: []const u8) !void {
                var off: usize = 0;
                while (off < data.len) {
                    const n = try self.s.write(data[off..]);
                    if (n == 0) break;
                    off += n;
                }
            }
            fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
                const buf = try std.fmt.allocPrint(self.a, fmt, args);
                defer self.a.free(buf);
                try self.writeAll(buf);
            }
        }{ .s = &conn.stream, .a = a };

        var buf: std.ArrayListUnmanaged(u8) = .{};
        defer buf.deinit(a);
        var tmp: [4096]u8 = undefined;
        var head_end: ?usize = null;
        while (true) {
            const n = try reader.read(&tmp);
            if (n == 0) break;
            try buf.appendSlice(a, tmp[0..n]);
            if (head_end == null) {
                if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |pos| head_end = pos + 4 else continue;
            }
            // compute content-length
            var cltmp: usize = 0;
            var it = std.mem.splitSequence(u8, buf.items[0..head_end.?], "\r\n");
            _ = it.next();
            while (it.next()) |line| {
                if (line.len == 0) break;
                if (std.mem.startsWith(u8, line, "Content-Length:")) {
                    cltmp = std.fmt.parseInt(usize, std.mem.trim(u8, line["Content-Length:".len..], " "), 10) catch 0;
                }
            }
            const have = buf.items.len - head_end.?;
            if (have >= cltmp) break;
        }

        const he = head_end orelse buf.items.len;
        const head = buf.items[0..he];
        // Parse request line
        var it = std.mem.splitSequence(u8, head, "\r\n");
        const req_line = it.next() orelse "";
        var it2 = std.mem.splitScalar(u8, req_line, ' ');
        const method = it2.next() orelse "";
        const target = it2.next() orelse "";

        if (!std.mem.eql(u8, method, "POST") or !std.mem.eql(u8, target, "/message")) {
            try writer.print("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
            continue;
        }

        // Extract Authorization header
        var authz: ?[]const u8 = null;
        var cl: usize = 0;
        var hscan = std.mem.splitSequence(u8, head, "\r\n");
        _ = hscan.next();
        while (hscan.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "Authorization:")) {
                authz = std.mem.trim(u8, line["Authorization:".len..], " ");
            } else if (std.mem.startsWith(u8, line, "Content-Length:")) {
                cl = std.fmt.parseInt(usize, std.mem.trim(u8, line["Content-Length:".len..], " "), 10) catch 0;
            }
        }
        const body = if (he + cl <= buf.items.len) buf.items[he .. he + cl] else buf.items[he..];

        if (authz == null) {
            try writer.print("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
            continue;
        }
        const authv = authz.?;
        const prefix = "Bearer ";
        if (authv.len <= prefix.len or !std.mem.startsWith(u8, authv, prefix)) {
            try writer.print("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
            continue;
        }
        const token = authv[prefix.len..];

        const parsed = parse_inbound_json(a, body) catch |e| {
            const msg = std.fmt.allocPrint(a, "Error: {s}", .{@errorName(e)}) catch body;
            try writer.print("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
            try writer.writeAll(msg);
            if (msg.ptr != body.ptr) a.free(msg);
            continue;
        };
        defer free_inbound_message(a, parsed);

        const user = verifyJwtForMessage(a, secret, token, parsed) catch |e| {
            switch (e) {
                AuthzError.InvalidToken => {
                    try writer.print("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
                    continue;
                },
                AuthzError.Forbidden => {
                    try writer.print("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
                    continue;
                },
                else => {
                    try writer.print("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
                    continue;
                },
            }
        };

        // Ownership enforcement: only the owner can control their object
        authorizeOwnership(reg, parsed, user) catch |e| {
            switch (e) {
                AuthzError.Forbidden => {
                    try writer.print("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
                    a.free(user);
                    continue;
                },
                else => {
                    try writer.print("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
                    a.free(user);
                    continue;
                },
            }
        };

        const cmd = InterpretFactory.makeWithUser(a, reg, router, parsed, user);
        a.free(user);
        var q = core.CommandQueue.init(a);
        defer q.deinit();
        _ = cmd.call(cmd.ctx, &q) catch |e| {
            const msg = std.fmt.allocPrint(a, "Error: {s}", .{@errorName(e)}) catch body;
            try writer.print("HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
            try writer.writeAll(msg);
            if (msg.ptr != body.ptr) a.free(msg);
            continue;
        };
        try writer.print("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
    }
}
