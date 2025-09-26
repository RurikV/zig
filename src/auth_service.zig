const std = @import("std");
const auth = @import("auth.zig");
const jwt = @import("jwt.zig");

const Allocator = std.mem.Allocator;

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

fn jsonError(a: Allocator, msg: []const u8) []u8 {
    // Small helper to build {"error":"msg"}
    var out: std.ArrayListUnmanaged(u8) = .{};
    var w = ListWriter{ .list = &out, .allocator = a };
    w.writeAll("{\"error\":") catch {};
    writeJsonString(&w, msg) catch {};
    w.writeAll("}") catch {};
    return out.toOwnedSlice(a) catch msg;
}

fn parseCreateGameRequest(a: Allocator, body: []const u8) !struct { participants: []const []const u8, game_id: ?[]const u8 } {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.Invalid;
    const obj = root.object;
    const part_v = obj.getPtr("participants") orelse return error.Invalid;
    if (part_v.* != .array) return error.Invalid;
    const arr = part_v.array.items;
    var tmp = try a.alloc([]const u8, arr.len);
    errdefer a.free(tmp);
    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        if (arr[i] != .string) return error.Invalid;
        tmp[i] = arr[i].string;
    }
    var gid: ?[]const u8 = null;
    if (obj.getPtr("game_id")) |g| {
        if (g.* == .string) gid = g.string else return error.Invalid;
    }
    return .{ .participants = tmp, .game_id = gid };
}

fn parseIssueTokenRequest(a: Allocator, body: []const u8) !struct { user: []const u8, game_id: []const u8 } {
    _ = a;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const u = obj.getPtr("user") orelse return error.Invalid;
    const g = obj.getPtr("game_id") orelse return error.Invalid;
    if (u.* != .string or g.* != .string) return error.Invalid;
    return .{ .user = u.string, .game_id = g.string };
}

pub fn run_auth_service(a: Allocator, address: []const u8) !void {
    var server = std.http.Server.init(.{ .reuse_address = true });
    defer server.deinit();

    var addr = try std.net.Address.resolveIp(address, 0);
    // default to 8081 for auth service
    addr.in.setPort(8081);
    try server.listen(addr);

    var store = auth.AuthStore.init(a);
    defer store.deinit();

    const secret = jwt.defaultSecret(a);
    const secret_is_owned = secret.len != "dev-secret".len or !std.mem.eql(u8, secret, "dev-secret");
    defer if (secret_is_owned) a.free(secret);

    while (true) {
        var conn = try server.accept();
        defer conn.deinit();
        var buf_reader = std.io.bufferedReader(conn.stream.reader());
        var req = try std.http.Server.Request.init(conn, buf_reader.reader());
        defer req.deinit();
        try req.wait();

        if (req.method == .POST and std.mem.eql(u8, req.head.target, "/games")) {
            const body = try req.reader().readAllAlloc(a, 1 << 20);
            defer a.free(body);
            const parsed = parseCreateGameRequest(a, body) catch |e| {
                const msg = jsonError(a, @errorName(e));
                _ = req.respond(.{ .status = .bad_request, .reason = "Bad Request", .body = msg }) catch {};
                a.free(msg);
                continue;
            };
            const gid = store.createGame(parsed.participants, parsed.game_id) catch |e| {
                const msg = jsonError(a, @errorName(e));
                _ = req.respond(.{ .status = .internal_server_error, .reason = "Internal", .body = msg }) catch {};
                a.free(msg);
                continue;
            };
            defer a.free(gid);
            var out: std.ArrayListUnmanaged(u8) = .{};
            var w = ListWriter{ .list = &out, .allocator = a };
            try w.writeAll("{\"game_id\":");
            try writeJsonString(&w, gid);
            try w.writeAll("}");
            const body_out = try out.toOwnedSlice(a);
            try req.respond(.{ .status = .created, .reason = "Created", .body = body_out });
            a.free(body_out);
            continue;
        }

        if (req.method == .POST and std.mem.eql(u8, req.head.target, "/token")) {
            const body = try req.reader().readAllAlloc(a, 1 << 20);
            defer a.free(body);
            const parsed = parseIssueTokenRequest(a, body) catch |e| {
                const msg = jsonError(a, @errorName(e));
                _ = req.respond(.{ .status = .bad_request, .reason = "Bad Request", .body = msg }) catch {};
                a.free(msg);
                continue;
            };
            const tok = store.issueToken(a, secret, parsed.user, parsed.game_id) catch |e| switch (e) {
                error.UnknownGame => blk: {
                    const msg = jsonError(a, "UnknownGame");
                    _ = req.respond(.{ .status = .not_found, .reason = "Not Found", .body = msg }) catch {};
                    a.free(msg);
                    continue;
                },
                error.NotParticipant => blk: {
                    const msg = jsonError(a, "NotParticipant");
                    _ = req.respond(.{ .status = .forbidden, .reason = "Forbidden", .body = msg }) catch {};
                    a.free(msg);
                    continue;
                },
                else => blk: {
                    const msg = jsonError(a, @errorName(e));
                    _ = req.respond(.{ .status = .internal_server_error, .reason = "Internal", .body = msg }) catch {};
                    a.free(msg);
                    continue;
                },
            };
            defer a.free(tok);
            var out: std.ArrayListUnmanaged(u8) = .{};
            var w = ListWriter{ .list = &out, .allocator = a };
            try w.writeAll("{\"token\":");
            try writeJsonString(&w, tok);
            try w.writeAll("}");
            const body_out = try out.toOwnedSlice(a);
            try req.respond(.{ .status = .ok, .reason = "OK", .body = body_out });
            a.free(body_out);
            continue;
        }

        try req.respond(.{ .status = .not_found, .reason = "Not Found" });
    }
}
