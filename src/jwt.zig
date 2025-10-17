const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Claims = struct {
    sub: []const u8, // subject (user)
    game_id: []const u8,
    exp: ?i64 = null, // unix seconds; optional
};

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
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

fn sha256(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

fn hmac_sha256(key: []const u8, data: []const u8) [32]u8 {
    const block_size: usize = 64; // SHA-256 block size
    var k_pad: [block_size]u8 = .{0} ** block_size;
    if (key.len > block_size) {
        const kh = sha256(key);
        @memcpy(k_pad[0..kh.len], &kh);
    } else {
        @memcpy(k_pad[0..key.len], key);
    }
    var ipad: [block_size]u8 = undefined;
    var opad: [block_size]u8 = undefined;
    for (k_pad, 0..) |b, i| {
        ipad[i] = b ^ 0x36;
        opad[i] = b ^ 0x5c;
    }
    // inner = SHA256(ipad || data)
    var sha1 = std.crypto.hash.sha2.Sha256.init(.{});
    sha1.update(&ipad);
    sha1.update(data);
    var inner: [32]u8 = undefined;
    sha1.final(&inner);
    // outer = SHA256(opad || inner)
    var sha2 = std.crypto.hash.sha2.Sha256.init(.{});
    sha2.update(&opad);
    sha2.update(&inner);
    var out: [32]u8 = undefined;
    sha2.final(&out);
    return out;
}

fn base64url_encode(a: Allocator, data: []const u8) ![]u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out_len = enc.calcSize(data.len);
    const buf = try a.alloc(u8, out_len);
    _ = enc.encode(buf, data);
    return buf;
}

fn base64url_decode(a: Allocator, text: []const u8) ![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const out_len = try dec.calcSizeForSlice(text);
    const buf = try a.alloc(u8, out_len);
    try dec.decode(buf, text);
    return buf;
}

fn build_header(a: Allocator) ![]u8 {
    // {"alg":"HS256","typ":"JWT"}
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(a);
    var w = ListWriter{ .list = &out, .allocator = a };
    try w.writeAll("{");
    try w.writeAll("\"alg\":\"HS256\",\"typ\":\"JWT\"");
    try w.writeAll("}");
    return try out.toOwnedSlice(a);
}

fn build_payload(a: Allocator, claims: Claims) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(a);
    var w = ListWriter{ .list = &out, .allocator = a };
    try w.writeAll("{");
    try w.writeAll("\"sub\":");
    try writeJsonString(&w, claims.sub);
    try w.writeAll(",\"game_id\":");
    try writeJsonString(&w, claims.game_id);
    if (claims.exp) |e| {
        try w.writeAll(",\"exp\":");
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{e});
        try w.writeAll(s);
    }
    try w.writeAll("}");
    return try out.toOwnedSlice(a);
}

pub fn encodeHS256(a: Allocator, secret: []const u8, claims: Claims) ![]u8 {
    const header_json = try build_header(a);
    defer a.free(header_json);
    const payload_json = try build_payload(a, claims);
    defer a.free(payload_json);

    const header_b64 = try base64url_encode(a, header_json);
    defer a.free(header_b64);
    const payload_b64 = try base64url_encode(a, payload_json);
    defer a.free(payload_b64);

    // signature = HMACSHA256( base64url(header) + "." + base64url(payload) )
    const sep = ".";
    const signing_input = try std.mem.concat(a, u8, &[_][]const u8{ header_b64, sep, payload_b64 });
    defer a.free(signing_input);

    const mac = hmac_sha256(secret, signing_input);
    const sig_b64 = try base64url_encode(a, mac[0..]);

    const token = try std.mem.concat(a, u8, &[_][]const u8{ header_b64, sep, payload_b64, sep, sig_b64 });
    a.free(sig_b64);
    return token;
}

pub const VerifyError = error{
    InvalidToken,
    InvalidJson,
    InvalidAlg,
    SignatureMismatch,
};

fn jsonStringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    if (obj.getPtr(name)) |v| {
        if (v.* == .string) return v.string;
    }
    return null;
}

pub fn verifyHS256(a: Allocator, secret: []const u8, token: []const u8) !Claims {
    // Split token into three parts
    var it = std.mem.splitScalar(u8, token, '.');
    const p0 = it.next() orelse return VerifyError.InvalidToken;
    const p1 = it.next() orelse return VerifyError.InvalidToken;
    const p2 = it.next() orelse return VerifyError.InvalidToken;
    if (it.next() != null) return VerifyError.InvalidToken;

    const header_raw = try base64url_decode(a, p0);
    defer a.free(header_raw);
    const payload_raw = try base64url_decode(a, p1);
    defer a.free(payload_raw);
    const sig_raw = try base64url_decode(a, p2);
    defer a.free(sig_raw);

    // Verify alg
    var parsed_h = try std.json.parseFromSlice(std.json.Value, a, header_raw, .{});
    defer parsed_h.deinit();
    if (parsed_h.value != .object) return VerifyError.InvalidJson;
    const hobj = parsed_h.value.object;
    const alg = jsonStringField(hobj, "alg") orelse return VerifyError.InvalidAlg;
    if (!std.mem.eql(u8, alg, "HS256")) return VerifyError.InvalidAlg;

    // Verify signature
    const sep = ".";
    const signing_input = try std.mem.concat(a, u8, &[_][]const u8{ p0, sep, p1 });
    defer a.free(signing_input);
    const mac = hmac_sha256(secret, signing_input);
    if (sig_raw.len != mac.len or std.mem.eql(u8, sig_raw, mac[0..]) == false) {
        // constant time compare
        var diff: u8 = 0;
        const min_len = if (sig_raw.len < mac.len) sig_raw.len else mac.len;
        var i: usize = 0;
        while (i < min_len) : (i += 1) diff |= sig_raw[i] ^ mac[i];
        diff |= @as(u8, @intCast(sig_raw.len ^ mac.len));
        if (diff != 0) return VerifyError.SignatureMismatch;
    }

    var parsed_p = try std.json.parseFromSlice(std.json.Value, a, payload_raw, .{});
    defer parsed_p.deinit();
    if (parsed_p.value != .object) return VerifyError.InvalidJson;
    const pobj = parsed_p.value.object;
    const sub = jsonStringField(pobj, "sub") orelse return VerifyError.InvalidJson;
    const gid = jsonStringField(pobj, "game_id") orelse return VerifyError.InvalidJson;

    var exp_val: ?i64 = null;
    if (pobj.getPtr("exp")) |ev| {
        switch (ev.*) {
            .integer => |ival| exp_val = @intCast(ival),
            .number_string => |ns| {
                const p = std.fmt.parseInt(i64, ns, 10) catch null;
                exp_val = p;
            },
            else => {},
        }
    }

    const out = Claims{
        .sub = try a.dupe(u8, sub),
        .game_id = try a.dupe(u8, gid),
        .exp = exp_val,
    };
    return out;
}

pub fn freeClaims(a: Allocator, c: Claims) void {
    a.free(c.sub);
    a.free(c.game_id);
}

pub fn defaultSecret(a: Allocator) []const u8 {
    if (std.process.getEnvVarOwned(a, "JWT_SECRET")) |s| {
        return s;
    } else |_| {}
    return "dev-secret";
}

test "JWT: encode and verify HS256" {
    const A = std.testing.allocator;
    const secret = "top-secret";
    const claims = Claims{ .sub = "alice", .game_id = "g1", .exp = null };
    const token = try encodeHS256(A, secret, claims);
    defer A.free(token);
    const out = try verifyHS256(A, secret, token);
    defer freeClaims(A, out);
    try std.testing.expectEqualStrings("alice", out.sub);
    try std.testing.expectEqualStrings("g1", out.game_id);
}
