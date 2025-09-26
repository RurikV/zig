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
    // Small helper to build {"error":"msg"}; always returns owned memory.
    var out: std.ArrayListUnmanaged(u8) = .{};
    var w = ListWriter{ .list = &out, .allocator = a };
    w.writeAll("{\"error\":") catch {};
    writeJsonString(&w, msg) catch {};
    w.writeAll("}") catch {};
    const owned = out.toOwnedSlice(a) catch null;
    if (owned) |s| return s;
    // Fallback: allocate a minimal message
    const fb = a.dupe(u8, "{\"error\":\"oom\"}") catch (a.alloc(u8, 0) catch unreachable);
    return fb;
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
    // Minimal HTTP/1.1 loop using TCP sockets for Zig version compatibility
    const addr = try std.net.Address.resolveIp(address, 8081);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();

    var store = auth.AuthStore.init(a);
    defer store.deinit();

    const secret = jwt.defaultSecret(a);
    const secret_is_owned = secret.len != "dev-secret".len or !std.mem.eql(u8, secret, "dev-secret");
    defer if (secret_is_owned) a.free(secret);

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

        // Read headers then body
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
            const head = buf.items[0..head_end.?];
            // find Content-Length
            var cl: usize = 0;
            var it = std.mem.splitSequence(u8, head, "\r\n");
            _ = it.next(); // request line
            while (it.next()) |line| {
                if (line.len == 0) break;
                if (std.mem.startsWith(u8, line, "Content-Length:")) {
                    const s = std.mem.trim(u8, line["Content-Length:".len..], " ");
                    cl = std.fmt.parseInt(usize, s, 10) catch 0;
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

        // Determine body length
        var cl: usize = 0;
        var hscan = std.mem.splitSequence(u8, head, "\r\n");
        _ = hscan.next();
        while (hscan.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.startsWith(u8, line, "Content-Length:")) {
                const s = std.mem.trim(u8, line["Content-Length:".len..], " ");
                cl = std.fmt.parseInt(usize, s, 10) catch 0;
            }
        }
        const body_off = he;
        const body = if (body_off + cl <= buf.items.len) buf.items[body_off .. body_off + cl] else buf.items[body_off..];

        if (!std.mem.eql(u8, method, "POST")) {
            try writer.print("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
            continue;
        }

        if (std.mem.eql(u8, target, "/games")) {
            const parsed = parseCreateGameRequest(a, body) catch |e| {
                const msg = jsonError(a, @errorName(e));
                try writer.print("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
                try writer.writeAll(msg);
                a.free(msg);
                continue;
            };
            const gid = store.createGame(parsed.participants, parsed.game_id) catch |e| {
                const msg = jsonError(a, @errorName(e));
                try writer.print("HTTP/1.1 500 Internal\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
                try writer.writeAll(msg);
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
            try writer.print("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body_out.len});
            try writer.writeAll(body_out);
            a.free(body_out);
            continue;
        } else if (std.mem.eql(u8, target, "/token")) {
            const parsed = parseIssueTokenRequest(a, body) catch |e| {
                const msg = jsonError(a, @errorName(e));
                try writer.print("HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
                try writer.writeAll(msg);
                a.free(msg);
                continue;
            };
            const tok = store.issueToken(a, secret, parsed.user, parsed.game_id) catch |e| switch (e) {
                error.UnknownGame => {
                    const msg = jsonError(a, "UnknownGame");
                    try writer.print("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
                    try writer.writeAll(msg);
                    a.free(msg);
                    continue;
                },
                error.NotParticipant => {
                    const msg = jsonError(a, "NotParticipant");
                    try writer.print("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
                    try writer.writeAll(msg);
                    a.free(msg);
                    continue;
                },
                else => {
                    const msg = jsonError(a, @errorName(e));
                    try writer.print("HTTP/1.1 500 Internal\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len});
                    try writer.writeAll(msg);
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
            try writer.print("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body_out.len});
            try writer.writeAll(body_out);
            a.free(body_out);
            continue;
        } else {
            try writer.print("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
            continue;
        }
    }
}
