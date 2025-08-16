# Zig Project with CI/CD

A Zig project with automated CI/CD pipeline using GitHub Actions.

## Project Structure

This project consists of:
- **Library**: A static library built from `src/root.zig`
- **Executable**: A command-line application built from `src/main.zig`
- **Tests**: Unit tests for both library and executable components

## Building

### Prerequisites
- Zig 0.14.1 or later

### Local Development

```bash
# Build the project
zig build

# Run tests
zig build test

# Run the executable
zig build run

# Clean build artifacts
rm -rf zig-cache zig-out
```

### Build Options

```bash
# Build for specific target
zig build -Dtarget=x86_64-linux

# Build with optimization
zig build -Doptimize=ReleaseFast

# Available optimization modes: Debug, ReleaseSafe, ReleaseFast, ReleaseSmall
```

## CI/CD Pipeline

This project uses GitHub Actions for continuous integration and deployment.

### Workflows

#### 1. CI/CD Pipeline (`.github/workflows/ci.yml`)

**Triggers:**
- Push to `main` or `master` branches
- Pull requests to `main` or `master` branches
- GitHub releases

**Jobs:**

##### Test Job
- **Matrix Testing**: Tests against Zig versions `0.14.1` and `master`
- **Platform**: Ubuntu Latest
- **Steps**:
  1. Checkout code
  2. Setup Zig toolchain
  3. Cache dependencies for faster builds
  4. Run unit tests (`zig build test`)
  5. Build project (`zig build`)

##### Build and Release Job
- **Cross-Platform**: Builds on Linux, Windows, and macOS
- **Dependencies**: Runs only after successful tests
- **Artifacts**: Creates platform-specific binaries
- **Steps**:
  1. Checkout code
  2. Setup Zig 0.14.1
  3. Cache dependencies
  4. Build for target platform
  5. Package artifacts (executable + library)
  6. Upload artifacts (30-day retention)
  7. **On Release**: Create and upload release archives

##### Security Scan Job
- **Tool**: Trivy vulnerability scanner
- **Output**: SARIF format for GitHub Security tab
- **Coverage**: Scans entire filesystem for vulnerabilities

### Artifacts

Each successful build produces:
- **Executable**: `zig` (platform-specific)
- **Library**: `libzig.a` (static library)

**Artifact Naming Convention:**
- Linux: `zig-linux-x86_64.tar.gz`
- Windows: `zig-windows-x86_64.zip`
- macOS: `zig-macos-x86_64.tar.gz`

### Caching Strategy

The pipeline uses GitHub Actions cache to speed up builds:
- **Zig Cache**: `~/.cache/zig` and `zig-cache/`
- **Cache Key**: Based on OS, Zig version, and `build.zig.zon` hash
- **Benefits**: Faster dependency resolution and compilation

### Dependency Management

- **Dependabot**: Configured to update GitHub Actions weekly
- **Configuration**: `.github/dependabot.yml`
- **Auto-updates**: GitHub Actions dependencies only

## Release Process

### Creating a Release

1. **Tag Version**: Create and push a Git tag
   ```bash
   git tag v1.0.0
   git push origin v1.0.0
   ```

2. **GitHub Release**: Create a release from the tag on GitHub
   - The CI/CD pipeline automatically builds and uploads artifacts
   - Cross-platform binaries are attached to the release

### Release Assets

Each release includes:
- `zig-linux-x86_64.tar.gz` - Linux x86_64 binary
- `zig-windows-x86_64.zip` - Windows x86_64 binary  
- `zig-macos-x86_64.tar.gz` - macOS x86_64 binary

## Security

- **Vulnerability Scanning**: Automated with Trivy
- **SARIF Integration**: Results appear in GitHub Security tab
- **Dependency Updates**: Automated via Dependabot

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Ensure tests pass locally: `zig build test`
5. Submit a pull request

The CI/CD pipeline will automatically:
- Run tests against multiple Zig versions
- Build cross-platform binaries
- Perform security scanning
- Provide build status feedback

## Troubleshooting

### Common Issues

**Build Failures:**
- Check Zig version compatibility (minimum 0.14.1)
- Verify `build.zig.zon` syntax
- Clear cache: `rm -rf zig-cache`

**Test Failures:**
- Run tests locally: `zig build test`
- Check for platform-specific issues
- Review test output in CI logs

**Artifact Issues:**
- Ensure proper artifact naming in workflow
- Check file permissions on Unix systems
- Verify target platform compatibility

### CI/CD Debug

To debug CI/CD issues:
1. Check the Actions tab in GitHub repository
2. Review job logs for specific errors
3. Test locally with same Zig version
4. Check artifact upload/download logs