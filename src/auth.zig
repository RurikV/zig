const std = @import("std");
const jwt = @import("jwt.zig");

const Allocator = std.mem.Allocator;

pub const Game = struct {
    participants: std.StringHashMapUnmanaged(void) = .{},

    pub fn init() Game {
        return .{};
    }
    pub fn deinit(self: *Game, a: Allocator) void {
        var it = self.participants.iterator();
        while (it.next()) |kv| {
            a.free(kv.key_ptr.*);
        }
        self.participants.deinit(a);
    }
    pub fn addParticipant(self: *Game, a: Allocator, user: []const u8) !void {
        try self.participants.put(a, try a.dupe(u8, user), {});
    }
    pub fn hasParticipant(self: *const Game, user: []const u8) bool {
        return self.participants.contains(user);
    }
};

pub const AuthStore = struct {
    allocator: Allocator,
    games: std.StringHashMapUnmanaged(Game) = .{},
    next_id: u64 = 1,

    pub fn init(a: Allocator) AuthStore { return .{ .allocator = a }; }

    pub fn deinit(self: *AuthStore) void {
        var it = self.games.iterator();
        while (it.next()) |kv| {
            var g = kv.value_ptr.*;
            g.deinit(self.allocator);
            self.allocator.free(kv.key_ptr.*);
        }
        self.games.deinit(self.allocator);
    }

    pub fn createGame(self: *AuthStore, participants: []const []const u8, provided_id: ?[]const u8) ![]u8 {
        const gid = if (provided_id) |pid| try self.allocator.dupe(u8, pid) else blk: {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "g-{}", .{self.next_id});
            self.next_id += 1;
            break :blk try self.allocator.dupe(u8, s);
        };
        errdefer self.allocator.free(gid);
        var g = Game.init();
        for (participants) |u| try g.addParticipant(self.allocator, u);
        try self.games.put(self.allocator, gid, g);
        return try self.allocator.dupe(u8, gid);
    }

    pub fn issueToken(self: *AuthStore, a: Allocator, secret: []const u8, user: []const u8, game_id: []const u8) ![]u8 {
        const gp = self.games.getPtr(game_id) orelse return error.UnknownGame;
        if (!gp.hasParticipant(user)) return error.NotParticipant;
        const claims = jwt.Claims{ .sub = user, .game_id = game_id, .exp = null };
        return try jwt.encodeHS256(a, secret, claims);
    }
};

test "AuthStore: create game and issue token" {
    const A = std.testing.allocator;
    var store = AuthStore.init(A);
    defer store.deinit();
    const gid = try store.createGame(&[_][]const u8{ "alice", "bob" }, null);
    defer A.free(gid);

    const secret = "s";
    const tok = try store.issueToken(A, secret, "alice", gid);
    defer A.free(tok);

    const claims = try jwt.verifyHS256(A, secret, tok);
    defer jwt.freeClaims(A, claims);
    try std.testing.expectEqualStrings("alice", claims.sub);
    try std.testing.expectEqualStrings(gid, claims.game_id);
}

test "AuthStore: NotParticipant error" {
    const A = std.testing.allocator;
    var store = AuthStore.init(A);
    defer store.deinit();
    const gid = try store.createGame(&[_][]const u8{ "alice" }, "g42");
    defer A.free(gid);
    try std.testing.expectError(error.NotParticipant, store.issueToken(A, "s", "mallory", gid));
}
