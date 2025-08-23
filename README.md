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
