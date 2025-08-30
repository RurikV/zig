# Space Battle: Movement and Rotation Engines (Zig)

SOLID-friendly core for a “Space Battle” game server implemented in Zig. The repository focuses on two independent engines:
- Movement: straight, uniform motion without deformation.
- Rotation: angular update around an axis.

Both engines are decoupled from concrete game objects via duck-typed interfaces (no inheritance needed). The code is covered by unit tests with talkative [TEST] logs.

## Overview

- Language: Zig 0.14.1+
- Library: `src/root.zig` implements engines and tests.
- Executable: `src/main.zig` only prints a small info message; all logic is exercised by tests.
- Build system: `build.zig` builds both a static library and an executable, and exposes `zig build test`.
- IoC container: `src/commands/ioc.zig` provides a SOLID-friendly, extensible factory via a single Resolve API with per-thread scopes.

## Quick Start

Prerequisites:
- Install Zig 0.14.1 or later.

Local usage:
```bash
# Build the project
zig build

# Run tests (shows detailed [TEST] progress lines)
zig build test

# Run the sample executable (prints a short hint)
zig build run

# Clean local build artifacts
rm -rf zig-cache zig-out
```

### Build options
```bash
# Build for a specific target
zig build -Dtarget=x86_64-linux

# Choose optimization profile
zig build -Doptimize=ReleaseFast
# Available: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
```

## Features

- Movement engine (straight uniform motion):
  - Reads position and velocity from any object implementing the expected interface.
  - Computes new position as pos + vel and writes it back.
  - Proper error propagation if position/velocity cannot be read or position cannot be written.
- Rotation engine:
  - Reads current orientation (angle) and angular velocity.
  - Updates orientation as angle + omega.
  - Proper error propagation if orientation cannot be read or written.
- Tests are “talkative” and print [TEST] logs so you can see progress and expected errors.

## Minimal API (duck-typed interfaces)

Your object can participate in movement if it provides these methods:
```zig
getPosition(self: *T) !Vec2
getVelocity(self: *T) !Vec2
setPosition(self: *T, new_pos: Vec2) !void
```
It can participate in rotation if it provides:
```zig
getOrientation(self: *T) !f64
getAngularVelocity(self: *T) !f64
setOrientation(self: *T, new_angle: f64) !void
```
Then simply call:
```zig
try Movement.step(&object);
try Rotation.step(&object);
```

## Tests Included

Movement:
- (12, 5) + (-7, 3) -> (5, 8)
- Error when position cannot be read
- Error when velocity cannot be read
- Error when position cannot be written

Rotation:
- Angle increases by angular velocity
- Error when orientation cannot be read
- Error when orientation cannot be written

Run with:
```bash
zig build test
```

## Project Structure

- src/root.zig — Vec2, Movement, Rotation, sample structs, and tests.
- src/main.zig — Minimal entry point printing guidance text.
- build.zig — Builds static library and executable; adds test targets.
- .github/workflows — CI workflows for tests, builds, and security scan.

## CI/CD

GitHub Actions run on pushes/PRs and releases (see `.github/workflows/ci.yml`):
- Matrix tests on Zig `0.14.1` and `master` (Ubuntu).
- Cross-platform builds for Linux, Windows, macOS (after tests pass).
- Artifacts: platform executables and static library.
- On release: archives are attached to the GitHub Release.

Artifacts naming (as configured):
- Linux: `zig-linux-x86_64.tar.gz`
- Windows: `zig-windows-x86_64.zip`
- macOS: `zig-macos-x86_64.tar.gz`

Caching:
- Uses `~/.cache/zig` and `zig-cache/` keyed by OS, Zig version, and `build.zig.zon` hash.

Code quality:
- `zig fmt --check` runs in CI to enforce formatting for Zig sources.
- Qodana is not used for Zig (unsupported); its workflow is manual-only.

Security:
- Trivy scanner produces SARIF uploaded to GitHub Security tab.
- Dependabot keeps GitHub Actions up to date.

## Contributing

- Run `zig build test` locally before opening a PR.
- Keep tests talkative and add new cases for new behaviors.

## Troubleshooting

Build fails?
- Ensure Zig ≥ 0.14.1
- Clear cache: `rm -rf zig-cache`

Tests fail?
- Run locally with the same Zig version: `zig build test`
- Check printed [TEST] logs for details

## Exception Handling (Commands & Handlers)

A pluggable mechanism to process commands with centralized error handling.

- Core abstraction: `Command { ctx: *anyopaque, call: *const fn(*anyopaque, *CommandQueue) !void, tag: CommandTag }`
- Queue: `CommandQueue` with `pushBack`, `pushFront`, `popFront` and allocator-aware storage.
- Factory: `CommandFactory(T, exec)` creates a thin thunk so any struct with an `exec` function can be turned into a `Command`.
- Logging: `LogBuffer` collects lines; `LogCtx` writes `"tag=<...> err=<...>"` entries.
- Handlers (strategies implemented):
  - `handlerRetryOnFirstFailure`: on first failure of a non-wrapper command, enqueue a one-time retry wrapper.
  - `handlerLogAfterRetryOnce`: if the one-time retry fails, enqueue a log command.
  - `handlerRetrySecondTime`: if the one-time retry fails, enqueue a second retry wrapper.
  - `handlerLogAfterSecondRetry`: if the second retry fails, enqueue a log command.

Supported strategies (compose handlers in order):
- First failure → retry; second failure → log:
  - `[ handlerRetryOnFirstFailure, handlerLogAfterRetryOnce ]`
- Retry twice, then log:
  - `[ handlerRetryOnFirstFailure, handlerRetrySecondTime, handlerLogAfterSecondRetry ]`

Minimal usage example:
```zig
const std = @import("std");
const core = @import("commands/core.zig");
const handlers = @import("commands/handlers.zig");

pub fn demo(alloc: std.mem.Allocator) !void {
    var q = core.CommandQueue.init(alloc);
    defer q.deinit();

    var buf = core.LogBuffer.init(alloc);
    defer buf.deinit();

    // Example command: always fails
    var job = core.AlwaysFailsCtx{};
    const make = core.CommandFactory(core.AlwaysFailsCtx, core.execAlwaysFails);
    try q.pushBack(make.make(&job, .always_fails));

    // Strategy: retry once then log
    const pipeline = [_]handlers.Handler{
        .{ .ctx = null, .call = handlers.handlerRetryOnFirstFailure },
        .{ .ctx = &buf, .call = handlers.handlerLogAfterRetryOnce },
    };

    handlers.process(&q, pipeline[0..]);

    // Inspect logs if needed: buf.lines.items
}
```

Tests cover both strategies (first fail → retry → log; retry twice → log) under `src/commands/tests_exceptions.zig`. Run them with `zig build test`.




## Macro Commands (Fuel, Rotation, Bridge/Repeater)

MacroCommand lets you compose several commands into one atomic operation that runs sub-commands sequentially and stops at the first failure (propagating an error). This enables extending behavior (per SOLID) by composing commands rather than modifying existing code.

Implemented building blocks in src/commands/macro.zig:
- MacroCtx + execMacro: sequential executor for a slice of commands.
- Fuel commands:
  - CheckFuelCommand: verifies fuel >= consumption, otherwise returns GameError.CommandException.
  - BurnFuelCommand: reduces fuel by the consumption rate.
- MoveCommand/RotateCommand wrappers: expose Movement/Rotation as Commands.
- ChangeVelocityCommand: rotates the instantaneous velocity vector by the same delta used in rotation. No-op for objects without velocity API.
- Bridge, NoOp, Repeater:
  - Bridge: delegates to a swappable inner command at runtime.
  - NoOp: does nothing; used to cancel/cut behavior.
  - Repeater: re-enqueues a target command to the queue for continuous execution.

Examples

1) Movement with fuel consumption (Check → Move → Burn):
```zig
const core = @import("commands/core.zig");
const macro = @import("commands/macro.zig");

// Define concrete thunks for your object type T
fn execCheckFuel_T(ctx: *macro.CheckFuelCtx(T), q: *core.CommandQueue) !void {
    return macro.execCheckFuel(T, ctx, q);
}
fn execMove_T(ctx: *macro.MoveCtx(T), q: *core.CommandQueue) !void {
    return macro.execMove(T, ctx, q);
}
fn execBurnFuel_T(ctx: *macro.BurnFuelCtx(T), q: *core.CommandQueue) !void {
    return macro.execBurnFuel(T, ctx, q);
}

pub fn moveWithFuel(alloc: std.mem.Allocator, obj: *T) !void {
    var q = core.CommandQueue.init(alloc);
    defer q.deinit();

    const MakeCheck = core.CommandFactory(macro.CheckFuelCtx(T), execCheckFuel_T);
    const MakeMove  = core.CommandFactory(macro.MoveCtx(T),       execMove_T);
    const MakeBurn  = core.CommandFactory(macro.BurnFuelCtx(T),   execBurnFuel_T);

    var c1 = macro.CheckFuelCtx(T){ .obj = obj };
    var c2 = macro.MoveCtx(T){ .obj = obj };
    var c3 = macro.BurnFuelCtx(T){ .obj = obj };

    const items = [_]core.Command{ MakeCheck.make(&c1, .flaky), MakeMove.make(&c2, .flaky), MakeBurn.make(&c3, .flaky) };

    var mctx = macro.MacroCtx{ .items = items[0..] };
    const MakeMacro = core.CommandFactory(macro.MacroCtx, macro.execMacro);
    const mcmd = MakeMacro.make(&mctx, .flaky);
    try mcmd.call(mcmd.ctx, &q);
}
```

2) Rotation that also changes velocity (Rotate → ChangeVelocity):
```zig
fn execRotate_T(ctx: *macro.RotateCtx(T), q: *core.CommandQueue) !void { return macro.execRotate(T, ctx, q); }
fn execChangeVel_T(ctx: *macro.ChangeVelCtx(T), q: *core.CommandQueue) !void { return macro.execChangeVelocity(T, ctx, q); }

var rctx = macro.RotateCtx(T){ .obj = obj };
var vctx = macro.ChangeVelCtx(T){ .obj = obj };
const seq = [_]core.Command{ MakeRot.make(&rctx, .flaky), MakeChv.make(&vctx, .flaky) };
var mctx = macro.MacroCtx{ .items = seq[0..] };
// Execute as above via execMacro
```

3) Continuous execution with cancellation (Bridge + Repeater):
- Bridge wraps a macro (or any command) and delegates to it on each execution.
- Repeater puts the Bridge back into the queue front to keep repeating.
- To stop, swap Bridge.inner to NoOp (no search/removal in the queue needed).

See the passing tests in src/commands/tests_macro.zig:
- Macro: CheckFuelCommand success/failure
- Macro: BurnFuelCommand reduces fuel
- Macro: MacroCommand aborts on first failure
- Macro: movement with fuel consumption
- Macro: ChangeVelocity rotates velocity and rotation macro
- Macro: ChangeVelocity no-op for object without velocity
- Macro: Bridge+Repeater repeats then stops after NoOp inject

Additional Modules

- src/commands/macro.zig — Macro/utility commands (fuel, velocity change, bridge/repeater) and game-level error.
- src/commands/tests_macro.zig — Macro and fuel/velocity tests with [TEST] logs.


## IoC Container (Extensible Factory)

A SOLID-friendly, extensible factory exposed via one API:
- Resolve returns a Command you must execute; registration and admin operations are modeled as commands too.
- Built-in admin ops: "IoC.Register", "Scopes.New", "Scopes.Current", and "IoC.Admin.Register" (to add custom admin ops at runtime).
- Scopes: per-thread current scope so different threads (or games) can have independent strategies.

Signatures:
- Resolve: IoC.Resolve(alloc, key: []const u8, arg0: ?*anyopaque, arg1: ?*anyopaque) -> core.Command
- FactoryFn: fn (allocator, args: [2]?*anyopaque) !core.Command
- AdminFn (for custom admin ops): fn (allocator, args: [2]?*anyopaque) !core.Command

Example 1: Register a move factory and use it (root scope)
```zig
const std = @import("std");
const core = @import("commands/core.zig");
const IoC = @import("commands/ioc.zig");

const MoveCtx = struct { obj: *Ship }; // your object
fn execMove(ctx: *MoveCtx, _: *core.CommandQueue) !void { try Movement.step(ctx.obj); }

fn factory_make_move(allocator: std.mem.Allocator, args: [2]?*anyopaque) !core.Command {
    const pobj: *Ship = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const mctx = try allocator.create(MoveCtx);
    mctx.* = .{ .obj = pobj };
    const Maker = core.CommandFactory(MoveCtx, execMove);
    return Maker.makeOwned(mctx, .flaky, false, false);
}

pub fn demo(alloc: std.mem.Allocator, ship: *Ship) !void {
    var q = core.CommandQueue.init(alloc);
    defer q.deinit();

    const key: []const u8 = "move";
    const fptr: *const IoC.FactoryFn = &factory_make_move;
    const reg = try IoC.Resolve(alloc, "IoC.Register", @ptrCast(@constCast(&key)), @ptrCast(@constCast(&fptr)));
    defer if (reg.drop) |d| d(reg.ctx, alloc);
    try reg.call(reg.ctx, &q);

    const cmd = try IoC.Resolve(alloc, key, ship, null);
    defer if (cmd.drop) |d| d(cmd.ctx, alloc);
    try cmd.call(cmd.ctx, &q);
}
```

Example 2: Per-scope strategies
```zig
const scopeA: []const u8 = "A";
const scopeB: []const u8 = "B";

// Create scopes
try (try IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&scopeA)), null)).call(cmd.ctx, &q);
try (try IoC.Resolve(A, "Scopes.New", @ptrCast(@constCast(&scopeB)), null)).call(cmd.ctx, &q);

// Set current to A and register move-once
try (try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&scopeA)), null)).call(cmd.ctx, &q);
try (try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key)), @ptrCast(@constCast(&factory_make_move)))).call(cmd.ctx, &q);

// Switch to B and register move-twice
try (try IoC.Resolve(A, "Scopes.Current", @ptrCast(@constCast(&scopeB)), null)).call(cmd.ctx, &q);
try (try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key)), @ptrCast(@constCast(&factory_make_move_twice)))).call(cmd.ctx, &q);
```

Example 3: Custom admin op (alias for Scopes.New)
```zig
const AdminAliasCtx = struct { name: []const u8 };
fn execAdminAlias(ctx: *AdminAliasCtx, q: *core.CommandQueue) !void {
    const inner = try IoC.Resolve(q.allocator, "Scopes.New", @ptrCast(@constCast(&ctx.name)), null);
    defer if (inner.drop) |d| d(inner.ctx, q.allocator);
    try inner.call(inner.ctx, q);
}

fn admin_new_scope_alias(allocator: std.mem.Allocator, args: [2]?*anyopaque) !core.Command {
    const pname: *const []const u8 = @ptrCast(@alignCast(args[0] orelse return error.Invalid));
    const Maker = core.CommandFactory(AdminAliasCtx, execAdminAlias);
    const c = try allocator.create(AdminAliasCtx);
    c.* = .{ .name = pname.* };
    return Maker.makeOwned(c, .flaky, false, false);
}

// Register the new admin key and use it
const alias: []const u8 = "Scopes.New2";
const fnptr: *const IoC.AdminFn = &admin_new_scope_alias;
try (try IoC.Resolve(A, "IoC.Admin.Register", @ptrCast(@constCast(&alias)), @ptrCast(@constCast(&fnptr)))).call(cmd.ctx, &q);
try (try IoC.Resolve(A, "Scopes.New2", @ptrCast(@constCast(&scopeC)), null)).call(cmd.ctx, &q);
```

Notes
- Multithreaded isolation: each thread has its own current scope; tests show two threads registering different strategies and acting independently.
- Admin ops are dispatched via a registry (polymorphic, open for extension) so IoC.Resolve and initialization remain closed to modification.
- See src/commands/tests_ioc.zig for end-to-end examples with [TEST] logs.

## Adapter Generator (Auto-generated Adapters via IoC)

Purpose: replace inheritance-based coupling with adapters that delegate interface operations to IoC strategies. This keeps core closed for modification and open for extension by registering new strategies.

Concept
- An adapter instance wraps a concrete object pointer (opaque for the adapter) and an interface name, e.g., "Spaceship.Operations.IMovable".
- Adapter methods call IoC with keys derived from the interface name:
  - "<iface>:position.get"  args: [ obj_ptr, out_ptr *Vec2 ]
  - "<iface>:velocity.get"  args: [ obj_ptr, out_ptr *Vec2 ]
  - "<iface>:position.set"  args: [ obj_ptr, in_ptr  *const Vec2 ]
  - Optional: "<iface>:finish" args: [ obj_ptr, null ]

Adapter builders
- Adapters are constructed via runtime-registered builders generated by AdapterAdminBuilder. There are no built-in adapter admin ops; register your interface name first using "Adapter.Register".

Minimal example (IMovable)
```zig
const core = @import("commands/core.zig");
const IoC = @import("commands/ioc.zig");
const adapter = @import("commands/adapter.zig");

// 1) Register factories used by the adapter
const key_pos_get: []const u8 = "Spaceship.Operations.IMovable:position.get";
const key_vel_get: []const u8 = "Spaceship.Operations.IMovable:velocity.get";
const key_pos_set: []const u8 = "Spaceship.Operations.IMovable:position.set";
// factories must obey signatures described above (see src/commands/tests_adapter.zig)

// 2) Create adapter via admin op and call methods
// Define a MovableSpec with Adapter(IFACE) returning a type that uses adapter.BaseInit/BaseCall* helpers (see tests), then:
const Mov = adapter.InterfaceAdapter("Spaceship.Operations.IMovable", MovableSpec);
var ad: *Mov = undefined;
const make_ad = try IoC.Resolve(A, "Adapter.Spaceship.Operations.IMovable", @ptrCast(&ship), @ptrCast(&ad));
try make_ad.call(make_ad.ctx, &q);

const p = try ad.getPosition();
try ad.setPosition(.{ .x = 10, .y = 20 });
```

Registering a new adapter builder at runtime
```zig
// Suppose you implemented an AdminFn that builds adapters for interface name IFACE
const IFACE: []const u8 = "My.Interface";
const builder: *const IoC.AdminFn = &make_my_interface_adapter;
try (try IoC.Resolve(A, "Adapter.Register", @ptrCast(&IFACE), @ptrCast(&builder))).call(cmd.ctx, &q);

// Now you can resolve: IoC.Resolve(A, "Adapter.My.Interface", obj_ptr, out_adapter_ptr)
```

Notes
- The adapter allocates short-lived keys on the heap for each call and frees them; you own the adapter pointer and must destroy it after use (allocator.destroy(adapter_ptr)).
- See src/commands/tests_adapter.zig for complete working examples (including optional finish()).

Scaffold example: custom interface "Weapons.IFireable"

1) Implement a Spec that generates an adapter type and delegates to IoC (already provided):
  - src/commands/example_fireable_adapter.zig defines FireableSpec with Adapter(IFACE) that returns a type with methods:
    - getAmmo() !u32  -> IoC key "<iface>:ammo.get"
    - fire() !void    -> IoC key "<iface>:fire"
    - reload(u32)     -> IoC key "<iface>:reload"

2) Register a builder AdminFn for your interface at runtime (using the generator):
```zig
const IoC = @import("commands/ioc.zig");
const example = @import("commands/example_fireable_adapter.zig");

var q = core.CommandQueue.init(A);
const IFACE: []const u8 = "Weapons.IFireable";
const builder: *const IoC.AdminFn = &example.FireableBuilder.make;
try (try IoC.Resolve(A, "Adapter.Register", @ptrCast(@constCast(&IFACE)), @ptrCast(@constCast(&builder)))).call(cmd.ctx, &q);
```

3) Register factories for your methods (per scope as needed):
```zig
const key_ammo_get: []const u8 = "Weapons.IFireable:ammo.get";
const key_fire: []const u8     = "Weapons.IFireable:fire";
const key_reload: []const u8   = "Weapons.IFireable:reload";
const FAmmoGet: *const IoC.FactoryFn = &my_factory_ammo_get;  // (obj, *u32)
const FFire: *const IoC.FactoryFn    = &my_factory_fire;      // (obj, null)
const FReload: *const IoC.FactoryFn  = &my_factory_reload;    // (obj, *const u32)
try (try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_ammo_get)), @ptrCast(@constCast(&FAmmoGet)))).call(cmd.ctx, &q);
try (try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_fire)), @ptrCast(@constCast(&FFire)))).call(cmd.ctx, &q);
try (try IoC.Resolve(A, "IoC.Register", @ptrCast(@constCast(&key_reload)), @ptrCast(@constCast(&FReload)))).call(cmd.ctx, &q);
```

4) Create and use the adapter:
```zig
const Fire = adapter.InterfaceAdapter("Weapons.IFireable", example.FireableSpec);
var fireable: *Fire = undefined;
try (try IoC.Resolve(A, "Adapter.Weapons.IFireable", obj_ptr, @ptrCast(&fireable))).call(cmd.ctx, &q);
const ammo = try fireable.getAmmo();
try fireable.fire();
try fireable.reload(10);
A.destroy(fireable);
```


### Note: Using InterfaceAdapter with AdapterAdminBuilder (Fireable example)
- The generic AdapterAdminBuilder works with adapter.InterfaceAdapter(IFACE, FireableSpec).
- You can register builders for different interface names (e.g., Weapons.IFireable, Alt.IFireable) and reuse the same Spec; the generated type will call IoC using the chosen IFACE.
- See src/commands/tests_adapter.zig test "Adapter Generator: FireableAdapter for multiple interface names" for a complete example demonstrating generalization and interface independence.


## Threaded Command Worker

A minimal multithreaded command execution subsystem that runs commands from a per-worker queue in a background thread.

Key points:
- Each Worker owns a thread-safe queue (protected by mutex + condition variable).
- Start/Stop are exposed as commands, so they compose with the existing command/handler ecosystem.
- Hard stop: terminates the loop immediately (remaining queued commands are not guaranteed to run).
- Soft stop: stops once the queue becomes empty (waits for all queued work to finish).
- Command execution exceptions are caught and do not terminate the worker thread.

Files:
- src/commands/threading.zig — Worker implementation and Start/HardStop/SoftStop commands.
- src/commands/tests_threading.zig — tests for start and both stop modes.

Quick usage:
```zig
const std = @import("std");
const core = @import("commands/core.zig");
const threading = @import("commands/threading.zig");

pub fn demo(alloc: std.mem.Allocator) !void {
    var w = threading.Worker.init(alloc);
    defer w.deinit();

    // Start the worker via command
    var q = core.CommandQueue.init(alloc);
    defer q.deinit();
    var sctx = threading.StartCtx{ .worker = &w };
    try q.pushBack(threading.ThreadingFactory.StartCommand(&sctx));
    // Process start command in the current thread
    while (q.popFront()) |cmd| { cmd.call(cmd.ctx, &q) catch {}; if (cmd.drop) |d| d(cmd.ctx, alloc); }

    // Optionally wait until the background thread reported it started
    w.waitStarted();

    // Enqueue some work items to be executed by the worker thread
    const NoopCtx = struct {};
    fn execNoop(_: *NoopCtx, _: *core.CommandQueue) !void {}
    const Maker = core.CommandFactory(NoopCtx, execNoop);
    var c = NoopCtx{};
    w.enqueue(Maker.make(&c, .flaky));

    // Graceful shutdown: wait until the queue drains
    var ss = threading.SoftStopCtx{ .worker = &w };
    try q.pushBack(threading.ThreadingFactory.SoftStopCommand(&ss));
    while (q.popFront()) |cmd| { cmd.call(cmd.ctx, &q) catch {}; if (cmd.drop) |d| d(cmd.ctx, alloc); }
}
```

