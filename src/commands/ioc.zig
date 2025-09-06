const std = @import("std");
const core = @import("core.zig");

// IoC container with single Resolve API and scope support.
// Resolve returns a Command which, when executed, performs the requested action
// (either an admin action like Scopes.* / IoC.Register, or a domain command like movement).
//
// Usage examples (see tests_ioc.zig):
//   // admin ops
//   try (try IoC.Resolve(alloc, "Scopes.New", &scope_name_ptr, null)).call(cmd.ctx, &q);
//
// Factory registration:
//   const f: *const IoC.FactoryFn = &factory_make_move;
//   // args: key string pointer, factory fn pointer
//   const cmd = try IoC.Resolve(alloc, "IoC.Register", &key_ptr, @ptrCast(@constCast(f)));
//   try cmd.call(cmd.ctx, &q);
//
// Domain resolution:
//   // args: arbitrary pointers required by the factory; here: object pointer
//   const cmd = try IoC.Resolve(alloc, "move_straight", obj_ptr, null);
//   try cmd.call(cmd.ctx, &q);

pub const FactoryFn = fn (allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command;
pub const AdminFn = fn (allocator: std.mem.Allocator, args: [2]?*anyopaque) anyerror!core.Command;

const Allocator = std.mem.Allocator;
const ThreadId = usize;

const Entry = struct { func: *const FactoryFn };

const Scope = struct {
    table: std.StringHashMapUnmanaged(Entry) = .{},

    fn put(self: *Scope, a: Allocator, key: []const u8, entry: Entry) !void {
        const dup = try a.dupe(u8, key);
        errdefer a.free(dup);
        try self.table.put(a, dup, entry);
    }

    fn get(self: *Scope, key: []const u8) ?Entry {
        return self.table.get(key);
    }

    fn deinit(self: *Scope, a: Allocator) void {
        var it = self.table.iterator();
        while (it.next()) |kv| a.free(kv.key_ptr.*);
        self.table.deinit(a);
    }
};

const State = struct {
    allocator: Allocator,
    mtx: std.Thread.Mutex = .{},
    scopes: std.StringHashMapUnmanaged(Scope) = .{},
    current_by_thread: std.AutoHashMapUnmanaged(ThreadId, []u8) = .{},
    admin_ops: std.StringHashMapUnmanaged(*const AdminFn) = .{},
    adapter_ops: std.StringHashMapUnmanaged(*const AdminFn) = .{},

    fn init(a: Allocator) State {
        return .{ .allocator = a };
    }

    fn deinit(self: *State) void {
        var it = self.scopes.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.deinit(self.allocator);
            self.allocator.free(kv.key_ptr.*);
        }
        self.scopes.deinit(self.allocator);
        var it2 = self.current_by_thread.iterator();
        while (it2.next()) |e| self.allocator.free(e.value_ptr.*);
        self.current_by_thread.deinit(self.allocator);
        var it3 = self.admin_ops.iterator();
        while (it3.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.admin_ops.deinit(self.allocator);
        var it4 = self.adapter_ops.iterator();
        while (it4.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.adapter_ops.deinit(self.allocator);
    }
};

// Global container state
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var state: State = undefined;
var initialized: bool = false;
var init_mtx: std.Thread.Mutex = .{};

fn ensure() void {
    if (initialized) return;
    init_mtx.lock();
    defer init_mtx.unlock();
    if (initialized) return;
    state = State.init(gpa.allocator());
    // create default root scope
    const s = Scope{};
    _ = state.scopes.put(state.allocator, "root", s) catch {};
    // init admin ops registry with built-ins (no branching)
    registerAdminBuiltin("IoC.Register", &opIoCRegister);
    registerAdminBuiltin("Scopes.New", &opScopesNew);
    registerAdminBuiltin("Scopes.Current", &opScopesCurrent);
    registerAdminBuiltin("IoC.Admin.Register", &opAdminRegister);
    // Adapter generator: no built-in adapters; only runtime-registered builders
    // Allow registering new adapter builders at runtime
    registerAdminBuiltin("Adapter.Register", &opAdapterRegister);
    initialized = true;
}

fn dupKey(s: []const u8) ?[]u8 {
    return state.allocator.dupe(u8, s) catch null;
}

fn registerAdminBuiltin(key: []const u8, fnptr: *const AdminFn) void {
    const dup = state.allocator.dupe(u8, key) catch return;
    _ = state.admin_ops.put(state.allocator, dup, fnptr) catch {
        state.allocator.free(dup);
        return;
    };
}

fn registerAdapterBuiltin(iface: []const u8, fnptr: *const AdminFn) void {
    const dup = state.allocator.dupe(u8, iface) catch return;
    _ = state.adapter_ops.put(state.allocator, dup, fnptr) catch {
        state.allocator.free(dup);
        return;
    };
}

fn getThreadId() ThreadId {
    return std.Thread.getCurrentId();
}

fn getOrCreateScope(name: []const u8) !*Scope {
    ensure();
    state.mtx.lock();
    defer state.mtx.unlock();
    if (state.scopes.getPtr(name)) |p| return p;
    const dup = try state.allocator.dupe(u8, name);
    errdefer state.allocator.free(dup);
    try state.scopes.put(state.allocator, dup, Scope{});
    return state.scopes.getPtr(dup).?;
}

fn setCurrentScopeForThread(scope_name: []const u8) !void {
    ensure();
    state.mtx.lock();
    defer state.mtx.unlock();
    // ensure scope exists
    if (state.scopes.getPtr(scope_name) == null) {
        const dup_s = try state.allocator.dupe(u8, scope_name);
        errdefer state.allocator.free(dup_s);
        try state.scopes.put(state.allocator, dup_s, Scope{});
    }
    // set mapping
    const tid = getThreadId();
    const dup = try state.allocator.dupe(u8, scope_name);
    errdefer state.allocator.free(dup);
    // remove previous
    if (state.current_by_thread.fetchRemove(tid)) |old| state.allocator.free(old.value);
    try state.current_by_thread.put(state.allocator, tid, dup);
}

fn getCurrentScopePtr() *Scope {
    ensure();
    state.mtx.lock();
    defer state.mtx.unlock();
    const tid = getThreadId();
    const name = state.current_by_thread.get(tid) orelse "root";
    return state.scopes.getPtr(name) orelse blk: {
        // lazily ensure root
        const dup = state.allocator.dupe(u8, name) catch "root";
        _ = state.scopes.put(state.allocator, dup, Scope{}) catch {};
        break :blk state.scopes.getPtr(dup).?;
    };
}

// ---------------- Commands (admin) ----------------
const CmdRegisterCtx = struct { key: []const u8, func: *const FactoryFn, scope_name: []const u8 };
fn execRegister(ctx: *CmdRegisterCtx, _: *core.CommandQueue) !void {
    ensure();
    state.mtx.lock();
    defer state.mtx.unlock();
    const scope = state.scopes.getPtr(ctx.scope_name) orelse blk: {
        const dup = try state.allocator.dupe(u8, ctx.scope_name);
        errdefer state.allocator.free(dup);
        try state.scopes.put(state.allocator, dup, Scope{});
        break :blk state.scopes.getPtr(dup).?;
    };
    try scope.put(state.allocator, ctx.key, .{ .func = ctx.func });
}

const CmdNewScopeCtx = struct { name: []const u8 };
fn execNewScope(ctx: *CmdNewScopeCtx, _: *core.CommandQueue) !void {
    _ = try getOrCreateScope(ctx.name);
}

const CmdSetCurrentCtx = struct { name: []const u8 };
fn execSetCurrent(ctx: *CmdSetCurrentCtx, _: *core.CommandQueue) !void {
    try setCurrentScopeForThread(ctx.name);
}

// Additional admin: register admin op at runtime
const CmdAdminRegisterCtx = struct { key: []const u8, func: *const AdminFn };
fn execAdminRegister(ctx: *CmdAdminRegisterCtx, _: *core.CommandQueue) !void {
    ensure();
    state.mtx.lock();
    defer state.mtx.unlock();
    const dup = try state.allocator.dupe(u8, ctx.key);
    errdefer state.allocator.free(dup);
    try state.admin_ops.put(state.allocator, dup, ctx.func);
}

// ---- Admin operation factories (polymorphic) ----
fn opIoCRegister(allocator: Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const pkey: *const []const u8 = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const pfunc: *const *const FactoryFn = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const scope_name = blk: {
        state.mtx.lock();
        const tid = getThreadId();
        const nm = state.current_by_thread.get(tid) orelse "root";
        state.mtx.unlock();
        break :blk nm;
    };
    const ctx = try allocator.create(CmdRegisterCtx);
    ctx.* = .{ .key = pkey.*, .func = pfunc.*, .scope_name = scope_name };
    const Maker = core.CommandFactory(CmdRegisterCtx, execRegister);
    return Maker.makeOwned(ctx, .flaky, false, false);
}

fn opScopesNew(allocator: Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const pname: *const []const u8 = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const ctx = try allocator.create(CmdNewScopeCtx);
    ctx.* = .{ .name = pname.* };
    const Maker = core.CommandFactory(CmdNewScopeCtx, execNewScope);
    return Maker.makeOwned(ctx, .flaky, false, false);
}

fn opScopesCurrent(allocator: Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const pname: *const []const u8 = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const ctx = try allocator.create(CmdSetCurrentCtx);
    ctx.* = .{ .name = pname.* };
    const Maker = core.CommandFactory(CmdSetCurrentCtx, execSetCurrent);
    return Maker.makeOwned(ctx, .flaky, false, false);
}

fn opAdminRegister(allocator: Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const pkey: *const []const u8 = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const pfunc: *const *const AdminFn = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const ctx = try allocator.create(CmdAdminRegisterCtx);
    ctx.* = .{ .key = pkey.*, .func = pfunc.* };
    const Maker = core.CommandFactory(CmdAdminRegisterCtx, execAdminRegister);
    return Maker.makeOwned(ctx, .flaky, false, false);
}

// Enable runtime registration of adapter builders
const CmdAdapterRegisterCtx = struct { key: []const u8, func: *const AdminFn };
fn execAdapterRegister(ctx: *CmdAdapterRegisterCtx, _: *core.CommandQueue) !void {
    ensure();
    state.mtx.lock();
    defer state.mtx.unlock();
    const dup = try state.allocator.dupe(u8, ctx.key);
    errdefer state.allocator.free(dup);
    try state.adapter_ops.put(state.allocator, dup, ctx.func);
}

fn opAdapterRegister(allocator: Allocator, args: [2]?*anyopaque) anyerror!core.Command {
    const pkey: *const []const u8 = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const pfunc: *const *const AdminFn = @ptrCast(@alignCast(args[1] orelse return error.Invalid));
    const ctx = try allocator.create(CmdAdapterRegisterCtx);
    ctx.* = .{ .key = pkey.*, .func = pfunc.* };
    const Maker = core.CommandFactory(CmdAdapterRegisterCtx, execAdapterRegister);
    return Maker.makeOwned(ctx, .flaky, false, false);
}

// -------------- Resolve API --------------
// args: a pair of optional pointers to arbitrary values, interpreted by factory/admin ops.
// For IoC.Register: args[0] = pointer to []const u8 (key), args[1] = *const FactoryFn
// For Scopes.New/Scopes.Current: args[0] = pointer to []const u8 (scopeName)
// For domain keys: args passed through to factory (both entries available)

pub fn Resolve(allocator: Allocator, key: []const u8, arg0: ?*anyopaque, arg1: ?*anyopaque) anyerror!core.Command {
    ensure();
    // 1) Adapter dispatcher: keys that start with "Adapter." can be routed via adapter builders
    if (key.len > 8 and std.mem.startsWith(u8, key, "Adapter.")) {
        const iface = key[8..];
        state.mtx.lock();
        const ab = state.adapter_ops.get(iface);
        state.mtx.unlock();
        if (ab) |fnptr| {
            return try fnptr(allocator, .{ arg0, arg1 });
        }
    }
    // 2) Try admin ops registry
    state.mtx.lock();
    const admin_fn = state.admin_ops.get(key);
    state.mtx.unlock();
    if (admin_fn) |fnptr| {
        return try fnptr(allocator, .{ arg0, arg1 });
    }
    // 3) Domain resolution in current scope
    const scope = getCurrentScopePtr();
    const entry = scope.get(key) orelse return error.UnknownKey;
    return try entry.func(allocator, .{ arg0, arg1 });
}
