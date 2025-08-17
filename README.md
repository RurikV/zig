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