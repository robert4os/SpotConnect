# Dev-Run: Development Build & Run Environment

This directory contains tools for rapid development iteration of the SpotConnect UPnP component.

## Quick Reference

### Shell Scripts

| Script | Purpose | Usage |
|--------|---------|-------|
| `run.sh` | Build and run with change detection | `./run.sh [--platform x86_64] [--clean] [--restart] [--kill] [--build-only]` |
| `logthis.sh` | Log management and analysis | `./logthis.sh [0\|1\|2]` |
| `analyze-log.sh` | Comprehensive log analysis | `./analyze-log.sh --file <log> --config <xml>` |
| `analyze-crash.sh` | Decode crash dumps | `./analyze-crash.sh` |

### Common Workflows

```bash
# Development cycle
./run.sh                  # Build if changed, start if needed
./run.sh --build-only     # Only compile if changed (no process management)
./run.sh --kill             # Kill running process only
./logthis.sh 1              # Snapshot current log to clipboard
./logthis.sh 2              # Full analysis with SPIRC debugging

# After crash
./analyze-crash.sh          # Decode addresses to source locations
cat ~/.spotconnect/gdb-crash.log  # Full GDB backtrace
```

---

## run.sh - Intelligent Build & Run

The `run.sh` script provides an intelligent, automated development workflow that:
- Detects source code and configuration changes
- Performs incremental or clean builds as needed
- Manages the application lifecycle (stop/start/restart)
- Monitors graceful shutdown sequences
- Maintains application logs

## Usage

### Basic Usage

```bash
./run.sh                        # Default: x86_64 platform
./run.sh --platform armv7       # Build for specific platform
./run.sh --clean                # Force clean rebuild
./run.sh --restart              # Force process restart
./run.sh --kill                 # Kill running process only
./run.sh --build-only           # Only compile (no process management)
./run.sh --platform x86_64 --clean --restart  # Combine flags
```

### Arguments

- `--platform <arch>` - Target platform architecture (default: x86_64)
  - Examples: x86_64, armv7, aarch64, i386
  - Must match the platform name used by the main build system
- `--clean` - Performs a clean build by completely removing the build directory
  - Forces CMake to regenerate all build files from scratch
  - Eliminates stale configuration and cached build artifacts
- `--restart` - Forces a process restart even if no changes are detected
- `--kill` - Only kills the running process, no build or restart (exits immediately)
- `--build-only` - Only compiles if code changed, skips all process management (exits after build)
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
  - Removes entire `build/` directory
  - Forces CMake to regenerate Makefiles and configuration
  - Ensures no stale build artifacts or cached configuration

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
| `--kill`, process running | Stop → Exit (no rebuild/restart) |
| `--kill`, process not running | Exit immediately |
| `--build-only`, changes detected | Rebuild → Exit (no process control) |
| `--build-only`, no changes | Exit immediately (skip rebuild) |

## Configuration

### Platform Selection

The script supports multiple architectures via the `--platform` parameter:

```bash
./run.sh --platform x86_64    # Intel/AMD 64-bit (default)
./run.sh --platform armv7     # ARM v7 (32-bit)
./run.sh --platform aarch64   # ARM 64-bit
./run.sh --platform i386      # Intel/AMD 32-bit
```

The platform name must match what the main build system expects.

### Paths and Settings

Core paths are configured at the top of `run.sh`:

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

- `run.sh` - Main development build and run script (this documentation)
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
2. **Run build script**: `./run.sh`
   - Detects changes automatically
   - Stops running process
   - Rebuilds only if needed
   - Starts new version
3. **Monitor output**: `tail -f ~/.spotconnect/spotupnp.log`
4. **Test your changes**
5. **Repeat**

### When to Use Each Mode

- **Normal mode** (`./run.sh`): 99% of the time - let the script decide
- **Platform switch** (`./run.sh --platform armv7`): Building for different architecture
- **Clean build** (`./run.sh --clean`): After major changes, CMake issues, dependency updates, or build problems
  - Removes entire build directory to force CMake regeneration
  - Use when encountering strange build errors or configuration issues
- **Restart** (`./run.sh --restart`): To restart without rebuilding (e.g., testing same binary)
- **Kill only** (`./run.sh --kill`): Stop the process without rebuilding or restarting
- **Build only** (`./run.sh --build-only`): Verify code compiles without affecting running process
- **Combined** (`./run.sh --platform aarch64 --clean`): Platform change with clean build

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
./run.sh --platform x86_64  # Explicitly specify platform

# Force rebuild
./run.sh --clean
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
./run.sh --clean

# Verify platform is supported
./run.sh --platform x86_64

# Check if all dependencies are available
cd ~/dev/spotconnect/spotupnp
bash run.sh x86_64 static clean
```

### "No changes detected but should rebuild"

The script uses Git to detect source changes. Make sure:
- You're in a Git repository
- Changes are visible to `git diff`
- Use `--clean` to force rebuild regardless

---

## logthis.sh - Log Management Interface

Unified log management tool with three modes of operation.

### Usage

```bash
./logthis.sh 0    # Reset: Clear both log files
./logthis.sh 1    # Snapshot: Copy log to clipboard and save to logthis.log
./logthis.sh 2    # Analyze: Run comprehensive analysis with auto-detected config
```

### Features

**Option 0 - Reset**:
- Clears `~/.spotconnect/spotupnp.log` (main log)
- Removes `dev-run/logthis.log` (analysis snapshot)
- Use before starting a new experiment

**Option 1 - Snapshot**:
- Strips ANSI color codes for clean viewing
- Copies to system clipboard (requires `xclip`)
- Saves to `dev-run/logthis.log` for persistent analysis
- Preserves original log file

**Option 2 - Analyze**:
- Runs `analyze-log.sh` with auto-detected config
- Provides comprehensive playback analysis
- Includes SPIRC protocol debugging
- Shows flow mode behavior and efficiency

### Log Locations

- **Main log**: `~/.spotconnect/spotupnp.log` (live, active log)
- **Snapshot**: `dev-run/logthis.log` (cleaned, for analysis)
- **Config**: `dev-run/config.xml` (auto-detected)

---

## analyze-log.sh - Comprehensive Log Analysis

Analyzes spotupnp logs and extracts playback metrics, configuration consistency, and SPIRC protocol behavior.

### Usage

```bash
# Auto-detect log and config
./analyze-log.sh

# Specify files explicitly
./analyze-log.sh --file <log> --config <config.xml>

# Analyze specific log
./analyze-log.sh --file /path/to/spotupnp.log

# Legacy format (positional argument)
./analyze-log.sh /path/to/spotupnp.log
```

### Analysis Sections

1. **Configuration Display**: Shows all config.xml settings at the top
2. **Session Info**: Binary version, startup time, device name
3. **Track Playback**: Complete list of tracks played with numbering
4. **Flow Mode Status**: FLOW_ACTIVE vs DISCRETE_MODE detection with HTTP port analysis
5. **Rate Limiting**: Efficiency percentages, expected vs actual timing
6. **Repeat Mode**: Loop detection with iteration count
7. **Errors & Warnings**: Count and recent entries with color coding
8. **Performance**: Latest rate limit status, seek operations
9. **Configuration Analysis**: Codec, bitrate, flow mode consistency checks
10. **Session Boundaries**: Session start/end markers
11. **SPIRC Protocol Analysis**: Frame types, PLAYBACK_START triggers, Load vs queued tracks
12. **Summary Statistics**: Tracks, mode, quality, efficiency, config status

### Color Coding

- **GREEN (✓)**: Success, OK, matches expected
- **YELLOW (⚠)**: Warning, mismatch, attention needed
- **RED (✗)**: Error, failed, problem detected
- **BLUE (ℹ)**: Information, pattern detected

### SPIRC Analysis Features

The analysis includes detailed SPIRC protocol debugging:
- **Frame counts**: Load, Notify, Play, Pause frames
- **Pattern detection**: Identifies single Load frame + queued tracks
- **Trigger details**: Shows what initiated each PLAYBACK_START
  - "Initiated by Spotify Load frame" = Spotify client command
  - "Auto-loaded from queue" = Internal queue mechanism
- **Track IDs**: Shows partial track ID for queued tracks

Example output:
```
=== SPIRC PROTOCOL ANALYSIS ===
Frame types received from Spotify:
  Load frames: 1
  Notify frames: 93

PLAYBACK_START event analysis:
  Total PLAYBACK_START events: 3
  Total Load frames: 1
  ℹ Pattern detected: 1 Load frame initiated session, 2 subsequent tracks auto-loaded from queue

Trigger details:
  Track 1: Initiated by Spotify Load frame
  Track 2: Auto-loaded from queue (trackId: e9900573d462...)
  Track 3: Auto-loaded from queue (trackId: bbe590aaab20...)
```

### Configuration Consistency Checks

- **Codec**: Compares config.xml codec with detected Content-Type
- **Bitrate**: Compares vorbis_rate with detected bitrate
- **Flow mode**: Compares config flow setting with actual behavior
- **Gapless**: Notes if gapless is enabled without flow mode

---

## analyze-crash.sh - Crash Dump Decoder

Decodes crash dumps and provides debugging information.

### Usage

```bash
# Analyze latest crash
./analyze-crash.sh

# Auto-detects:
# - /tmp/spotupnp-crash-latest.txt (crash dump)
# - ~/.spotconnect/.binary_path (binary location)
```

### Features

- Decodes raw memory addresses to source file:line
- Uses `addr2line` with the actual binary
- Shows function names and exact crash locations
- Displays full stack trace with source attribution
- Provides GDB debugging instructions

### Output

The script shows:
1. Crash signal and fault address
2. Full backtrace with decoded addresses
3. Source file locations (e.g., `spotify.cpp:218`)
4. Function names
5. Instructions for further debugging

### GDB Integration

The program runs under GDB when started via `run.sh`, which creates:
- `~/.spotconnect/gdb-crash.log` - Full GDB backtrace with locals, registers, threads
- `~/.spotconnect/.gdbinit` - GDB configuration for crash capture

After a crash:
```bash
# View simple decoded backtrace
./analyze-crash.sh

# View full GDB capture with locals and registers
cat ~/.spotconnect/gdb-crash.log
```

### Manual GDB Analysis

For deeper debugging:
```bash
# If core dump exists
gdb path/to/spotupnp-linux-x86_64-static core.*

# Within GDB
(gdb) bt full              # Full backtrace with local variables
(gdb) info threads         # All thread states
(gdb) thread apply all bt  # Backtrace of all threads
(gdb) frame N              # Switch to specific frame
(gdb) info locals          # Local variables in current frame
(gdb) p variable           # Print specific variable
```

---

## Files in dev-run/

| File | Purpose | Created By |
|------|---------|------------|
| `run.sh` | Build and run script | Manual |
| `logthis.sh` | Log management | Manual |
| `analyze-log.sh` | Log analysis | Manual |
| `analyze-crash.sh` | Crash decoder | Manual |
| `config.xml` | Local device config | `run.sh` (first run) |
| `logthis.log` | Log snapshot | `logthis.sh 1` |
| `README.md` | This file | Manual |

---

## Best Practices

1. **Keep it running**: Let the script manage the process lifecycle
2. **Monitor logs**: Keep `tail -f` running in another terminal during development
3. **Use normal mode**: The smart detection works well for most scenarios
4. **Commit often**: Change detection relies on Git status
5. **Clean builds**: Do a clean build after pulling major changes

## Integration with Main Build System

This script is **separate** from the main project build system:
- Main build: `spotupnp/run.sh` (production builds)
- Dev build: `dev-run/run.sh` (rapid iteration)

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
