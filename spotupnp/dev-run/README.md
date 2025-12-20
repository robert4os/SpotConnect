# Dev-Run: Development Build & Run Environment

This directory contains tools for rapid development iteration of the SpotConnect UPnP component.

## Overview

The `build.sh` script provides an intelligent, automated development workflow that:
- Detects source code and configuration changes
- Performs incremental or clean builds as needed
- Manages the application lifecycle (stop/start/restart)
- Monitors graceful shutdown sequences
- Maintains application logs

## Usage

### Basic Usage

```bash
./build.sh                        # Default: x86_64 platform
./build.sh --platform armv7       # Build for specific platform
./build.sh --clean                # Force clean rebuild
./build.sh --restart              # Force process restart
./build.sh --platform x86_64 --clean --restart  # Combine flags
```

### Arguments

- `--platform <arch>` - Target platform architecture (default: x86_64)
  - Examples: x86_64, armv7, aarch64, i386
  - Must match the platform name used by the main build system
- `--clean` - Performs a clean build by removing the build directory first
- `--restart` - Forces a process restart even if no changes are detected
- Arguments can be combined in any order

## How It Works

### 1. Platform Detection

The script automatically handles platform-specific builds:

- **Platform Parameter**: Accepts `--platform <arch>` (defaults to x86_64)
- **Dynamic Paths**: Constructs build directory based on platform: `build/linux-<platform>`
- **Binary Scanning**: Automatically searches for `spotupnp-linux-<platform>-static` in the build directory
- **Validation**: Errors if multiple or no matching binaries found after build

### 2. Change Detection

The script intelligently detects when rebuilds or restarts are needed:

- **Source Code Changes**: Uses `git diff` to detect uncommitted changes in the `src/` directory
- **Configuration Changes**: Compares MD5 hash of `config.xml` against previous run
- **Binary Existence**: Checks if the compiled binary exists

### 3. Process Management

- **Graceful Shutdown**: Sends SIGTERM and monitors log file for shutdown completion
- **Shutdown Timeout**: Waits up to 5 seconds for graceful shutdown
- **Force Kill**: Uses SIGKILL if graceful shutdown fails
- **Startup Verification**: Confirms process started successfully after launch

### 4. Build Optimization

The script avoids unnecessary rebuilds:
- If no source changes detected and binary exists → skip rebuild
- If source changed or binary missing → automatic rebuild
- Use `--clean` to force a complete rebuild from scratch

### 5. Smart Behavior

The script makes intelligent decisions based on current state:

| Scenario | Action |
|----------|--------|
| No changes, process running | Do nothing (skip) |
| No changes, process not running | Start process |
| Changes detected, process running | Stop → Rebuild → Start |
| Changes detected, process not running | Rebuild → Start |
| `--restart`, process running | Stop → Start (no rebuild unless needed) |
| `--restart`, process not running | Start (no rebuild unless needed) |

## Configuration

### Platform Selection

The script supports multiple architectures via the `--platform` parameter:

```bash
./build.sh --platform x86_64    # Intel/AMD 64-bit (default)
./build.sh --platform armv7     # ARM v7 (32-bit)
./build.sh --platform aarch64   # ARM 64-bit
./build.sh --platform i386      # Intel/AMD 32-bit
```

The platform name must match what the main build system expects.

### Paths and Settings

Core paths are configured at the top of `build.sh`:

```bash
PLATFORM="x86_64"  # Default, can be overridden with --platform
BUILD_DIR="$HOME/dev/spotconnect/spotupnp"
CONFIG_FILE="$HOME/dev/spotconnect/dev-run/config.xml"
SPOTCONNECT_DIR="$HOME/.spotconnect"
LOG_FILE="$SPOTCONNECT_DIR/spotupnp.log"
```

Derived automatically:
- Build output: `$BUILD_DIR/build/linux-$PLATFORM`
- Binary name: `spotupnp-linux-$PLATFORM-static`
- Binary path: Scanned automatically in build output directory

### First Run

On first run, if `config.xml` doesn't exist, the script will:
1. Generate a default configuration using `spotupnp -i`
2. Save it to `dev-run/config.xml`
3. Prompt you to customize the settings

## Files in This Directory

- `build.sh` - Main development build and run script (this documentation)
- `config.xml` - Application configuration for development testing
- `README.md` - This documentation file

## Runtime Artifacts

The script manages these files in `~/.spotconnect/`:

- `spotupnp.log` - Application stdout and stderr output
- `.config_hash` - MD5 hash of last-used config file (for change detection)

## Log Management

### Viewing Logs

```bash
# Follow log in real-time
tail -f ~/.spotconnect/spotupnp.log

# View recent log entries
tail -100 ~/.spotconnect/spotupnp.log

# Search for errors
grep -i error ~/.spotconnect/spotupnp.log
```

### Log Structure

Each process start writes a clear banner with:
- Start timestamp
- Binary name and version
- Configuration file path
- Hostname and system info

This makes it easy to distinguish between different runs in the log file.

## Process Control

### Manual Process Management

```bash
# Check if process is running (replace x86_64 with your platform)
pgrep -f spotupnp-linux-x86_64-static

# Stop the process gracefully
pkill -TERM -f spotupnp-linux-.*-static

# Force kill (if graceful shutdown fails)
pkill -KILL -f spotupnp-linux-.*-static

# View process details
ps aux | grep spotupnp
```

## Development Workflow

### Typical Development Cycle

1. **Make code changes** in `spotupnp/src/`
2. **Run build script**: `./build.sh`
   - Detects changes automatically
   - Stops running process
   - Rebuilds only if needed
   - Starts new version
3. **Monitor output**: `tail -f ~/.spotconnect/spotupnp.log`
4. **Test your changes**
5. **Repeat**

### When to Use Each Mode

- **Normal mode** (`./build.sh`): 99% of the time - let the script decide
- **Platform switch** (`./build.sh --platform armv7`): Building for different architecture
- **Clean build** (`./build.sh --clean`): After major changes, CMake issues, or dependency updates
- **Restart** (`./build.sh --restart`): To restart without rebuilding (e.g., testing same binary)
- **Combined** (`./build.sh --platform aarch64 --clean`): Platform change with clean build

## Troubleshooting

### Process Won't Start

```bash
# Check the log for startup errors
tail -50 ~/.spotconnect/spotupnp.log

# Verify binary exists (adjust platform as needed)
ls -lh ~/dev/spotconnect/spotupnp/build/linux-x86_64/spotupnp-linux-x86_64-static

# Try manual start for detailed output
cd ~/dev/spotconnect/spotupnp/build/linux-x86_64
./spotupnp-linux-x86_64-static -z -x ~/dev/spotconnect/dev-run/config.xml
```

### Binary Not Found

```bash
# Check what binaries exist in build directory
ls -lh ~/dev/spotconnect/spotupnp/build/linux-*/spotupnp-*

# Verify platform matches
./build.sh --platform x86_64  # Explicitly specify platform

# Force rebuild
./build.sh --clean
```

### Process Won't Stop

The script monitors shutdown for 5 seconds, then force-kills if needed. If issues persist:

```bash
# Nuclear option - force kill all spotupnp processes
killall -9 spotupnp-linux-x86_64-static
```

### Build Failures

```bash
# Try a clean build
./build.sh --clean

# Verify platform is supported
./build.sh --platform x86_64

# Check if all dependencies are available
cd ~/dev/spotconnect/spotupnp
bash build.sh x86_64 static clean
```

### "No changes detected but should rebuild"

The script uses Git to detect source changes. Make sure:
- You're in a Git repository
- Changes are visible to `git diff`
- Use `--clean` to force rebuild regardless

## Best Practices

1. **Keep it running**: Let the script manage the process lifecycle
2. **Monitor logs**: Keep `tail -f` running in another terminal during development
3. **Use normal mode**: The smart detection works well for most scenarios
4. **Commit often**: Change detection relies on Git status
5. **Clean builds**: Do a clean build after pulling major changes

## Integration with Main Build System

This script is **separate** from the main project build system:
- Main build: `spotupnp/build.sh` (production builds)
- Dev build: `dev-run/build.sh` (rapid iteration)

The dev script calls the main build script internally but adds:
- Change detection
- Process management  
- Automated restart
- Log monitoring

## Notes

- This script is designed for **local development only**
- Not intended for production deployment
- Configuration in `dev-run/config.xml` is local and not tracked in the main docs
- Process runs in background/daemon mode for development convenience
- **Platform**: The script automatically detects binaries for the specified platform
- **Cross-compilation**: Ensure your system can build for the target platform
- **Platform naming**: Must match the conventions used by the main build system
