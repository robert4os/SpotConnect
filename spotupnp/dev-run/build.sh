#!/bin/bash

# Configuration
PLATFORM="x86_64"  # Default platform
BUILD_DIR="$HOME/dev/spotconnect/spotupnp"
CONFIG_FILE="$HOME/dev/spotconnect/spotupnp/dev-run/config.xml"
SPOTCONNECT_DIR="$HOME/.spotconnect"
LOG_FILE="$SPOTCONNECT_DIR/spotupnp.log"
CONFIG_HASH_FILE="$SPOTCONNECT_DIR/.config_hash"
SOURCE_HASH_FILE="$SPOTCONNECT_DIR/.source_hash"
BINARY_PATH_FILE="$SPOTCONNECT_DIR/.binary_path"
CLEAN_BUILD=false
RESTART=false

# Parse all command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --restart)
            RESTART=true
            shift
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            echo "Usage: $0 [--platform <arch>] [--clean] [--restart]"
            echo "  --platform <arch> : Target platform architecture (default: x86_64)"
            echo "  --clean           : Perform clean build (removes build directory)"
            echo "  --restart         : Restart process regardless of changes"
            echo ""
            echo "Examples:"
            echo "  $0                        # Use default platform (x86_64)"
            echo "  $0 --platform armv7       # Build for ARM v7"
            echo "  $0 --clean --restart      # Clean build and restart"
            exit 1
            ;;
    esac
done

# Derive platform-dependent paths
# Scan for binary in build directories
echo "==> Detecting binary for platform: $PLATFORM"
FOUND_BINARIES=($(find "$BUILD_DIR/build" -maxdepth 2 -type f -name "spotupnp-*$PLATFORM-static" 2>/dev/null))

if [[ ${#FOUND_BINARIES[@]} -eq 0 ]]; then
    echo "    No binary found yet (will build)"
    # Try to determine build output directory from existing directories
    BUILD_OUTPUT_DIR=$(find "$BUILD_DIR/build" -maxdepth 1 -type d -name "*$PLATFORM" 2>/dev/null | head -n1)
    if [[ -z "$BUILD_OUTPUT_DIR" ]]; then
        # Fallback - we'll discover it after build
        BUILD_OUTPUT_DIR="$BUILD_DIR/build"
    fi
    BINARY_PATH=""
    BINARY_NAME="spotupnp-*$PLATFORM-static"
elif [[ ${#FOUND_BINARIES[@]} -eq 1 ]]; then
    BINARY_PATH="${FOUND_BINARIES[0]}"
    BINARY_NAME="$(basename "$BINARY_PATH")"
    BUILD_OUTPUT_DIR="$(dirname "$BINARY_PATH")"
    echo "    Found: $BINARY_NAME"
    echo "    Path: $BUILD_OUTPUT_DIR"
else
    echo "    ERROR: Multiple binaries found for platform $PLATFORM:"
    for bin in "${FOUND_BINARIES[@]}"; do
        echo "      - $(basename "$bin") in $(dirname "$bin")"
    done
    exit 1
fi
echo ""

# Display script mode
echo "==> Quick Development Build and Run Script"
if [[ "$CLEAN_BUILD" == "true" && "$RESTART" == "true" ]]; then
    echo "    Mode: CLEAN BUILD + RESTART"
elif [[ "$CLEAN_BUILD" == "true" ]]; then
    echo "    Mode: CLEAN BUILD"
elif [[ "$RESTART" == "true" ]]; then
    echo "    Mode: RESTART"
else
    echo "    Mode: NORMAL (use --clean or --restart for special modes)"
fi
echo ""

# Check if ANY spotupnp binary process is running (platform-agnostic)
# Check actual executable via /proc filesystem to distinguish from viewers
echo "==> Checking for any running spotupnp process..."
PROCESS_RUNNING=false
RUNNING_BINARY=""

# Find processes with spotupnp in their command, then verify actual executable
for pid in $(pgrep -f "spotupnp"); do
    # Get the actual executable path via /proc
    if [[ -e "/proc/$pid/exe" ]]; then
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null)
        # Check if it's actually a spotupnp binary (not tail, grep, etc.)
        if [[ "$exe" =~ spotupnp-.*-static$ ]]; then
            RUNNING_BINARY="$exe"
            echo "    Found running process: $(basename "$RUNNING_BINARY") (PID: $pid)"
            if [[ -n "$BINARY_NAME" && "$(basename "$RUNNING_BINARY")" != "$BINARY_NAME" ]]; then
                echo "    WARNING: Different platform binary is running!"
                echo "             Running: $(basename "$RUNNING_BINARY")"
                echo "             Target:  $BINARY_NAME"
            fi
            PROCESS_RUNNING=true
            break  # Found one, that's enough
        fi
    fi
done

if [[ "$PROCESS_RUNNING" == "false" ]]; then
    echo "    No running process found"
fi

echo ""

# Create spotconnect directory early to store hash file
mkdir -p "$SPOTCONNECT_DIR"

# Check if config file exists, if not create it
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "==> Config file not found: $CONFIG_FILE"
    
    # We need a binary to generate config - ensure we have one
    if [[ -z "$BINARY_PATH" || ! -f "$BINARY_PATH" ]]; then
        echo "    Cannot create config file - no binary available yet"
        echo "    Will create after build completes"
    else
        echo "    Creating default config file..."
        
        # Ensure config directory exists
        mkdir -p "$(dirname "$CONFIG_FILE")"
        
        # Run spotupnp with -i to generate default config
        cd "$BUILD_OUTPUT_DIR"
        if "./$BINARY_NAME" -i "$CONFIG_FILE"; then
            echo "    ✓ Config file created successfully"
            echo ""
            echo "    IMPORTANT: A default configuration has been created."
            echo "    You may want to edit it to customize settings:"
            echo "    - Edit: $CONFIG_FILE"
            echo "    - See README.md for available options"
            echo ""
            CONFIG_CHANGED=true
        else
            echo "    ERROR: Failed to create config file"
            echo "    The application will run with defaults, but config won't be saved"
            echo ""
        fi
    fi
fi

# Check if config file has changed
echo "==> Checking for config file changes..."
CONFIG_CHANGED=${CONFIG_CHANGED:-false}
CURRENT_CONFIG_HASH=""
PREVIOUS_CONFIG_HASH=""

if [[ -f "$CONFIG_FILE" ]]; then
    CURRENT_CONFIG_HASH=$(md5sum "$CONFIG_FILE" | awk '{print $1}')
    
    if [[ -f "$CONFIG_HASH_FILE" ]]; then
        PREVIOUS_CONFIG_HASH=$(cat "$CONFIG_HASH_FILE")
        
        if [[ "$CURRENT_CONFIG_HASH" != "$PREVIOUS_CONFIG_HASH" ]]; then
            echo "    Config file has changed"
            CONFIG_CHANGED=true
        else
            echo "    No config changes detected"
        fi
    else
        echo "    First run - no previous config hash found"
        CONFIG_CHANGED=true
    fi
else
    echo "    WARNING: Config file still not found: $CONFIG_FILE"
fi

echo ""

# Check if the source code has been changed
echo "==> Checking for source code changes..."
cd "$BUILD_DIR"
SOURCE_CHANGED=false

# Calculate comprehensive hash including:
# - src/ directory (our code)
# - CMakeLists.txt (build config)
# - build.sh (build script)
# - cspot submodule commit (git rev-parse HEAD in submodule)
CURRENT_SOURCE_HASH=""
{
    # Hash source files
    if [[ -d "src" ]]; then
        find src -type f \( -name "*.c" -o -name "*.cpp" -o -name "*.h" -o -name "*.hpp" \) -exec md5sum {} \; 2>/dev/null | sort
    fi
    
    # Hash build configuration
    [[ -f "CMakeLists.txt" ]] && md5sum CMakeLists.txt 2>/dev/null
    [[ -f "build.sh" ]] && md5sum build.sh 2>/dev/null
    
    # Hash cspot submodule commit
    if [[ -d "../common/cspot/.git" ]]; then
        echo "cspot: $(cd ../common/cspot && git rev-parse HEAD 2>/dev/null)"
    fi
    
    # Hash other critical dependencies
    [[ -f "../common/cspot/CMakeLists.txt" ]] && md5sum ../common/cspot/CMakeLists.txt 2>/dev/null
} | md5sum | awk '{print $1}' > /tmp/source_hash_calc.tmp

CURRENT_SOURCE_HASH=$(cat /tmp/source_hash_calc.tmp)
rm -f /tmp/source_hash_calc.tmp

if [[ -f "$SOURCE_HASH_FILE" ]]; then
    PREVIOUS_SOURCE_HASH=$(cat "$SOURCE_HASH_FILE")
    
    if [[ "$CURRENT_SOURCE_HASH" != "$PREVIOUS_SOURCE_HASH" ]]; then
        echo "    Source code changes detected"
        SOURCE_CHANGED=true
    else
        echo "    No source changes detected since last build"
    fi
else
    echo "    First build - no previous source hash found"
    SOURCE_CHANGED=true
fi

echo ""

# Check if binary exists
BINARY_EXISTS=false
if [[ -f "$BINARY_PATH" ]]; then
    BINARY_EXISTS=true
fi

# Decide what to do based on changes and process state
SOMETHING_CHANGED=false
if [[ "$SOURCE_CHANGED" == "true" || "$CONFIG_CHANGED" == "true" ]]; then
    SOMETHING_CHANGED=true
fi

# If restart flag is set, we'll always restart
if [[ "$RESTART" == "true" ]]; then
    if [[ "$PROCESS_RUNNING" == "false" ]]; then
        echo "==> Restart requested, but no process running"
        echo "    Will start the process..."
    fi
    # Continue to handle process killing and starting below
elif [[ "$SOMETHING_CHANGED" == "false" && "$PROCESS_RUNNING" == "true" ]]; then
    # If nothing changed and process is running (and not restart), abort
    echo "========================================="
    echo "No action needed:"
    echo "  - Source code: unchanged"
    echo "  - Config file: unchanged"
    echo "  - Process: already running"
    echo ""
    echo "Everything is up to date and running."
    echo "========================================="
    return 0 2>/dev/null || exit 0
fi

# If nothing changed but no process running, we'll start it
if [[ "$RESTART" == "false" && "$SOMETHING_CHANGED" == "false" && "$PROCESS_RUNNING" == "false" ]]; then
    echo "==> No changes detected, but process not running"
    echo "    Will start the process..."
    echo ""
fi

# If something changed and process is running, OR restart requested and process running, kill it
if [[ "$PROCESS_RUNNING" == "true" && ("$SOMETHING_CHANGED" == "true" || "$RESTART" == "true") ]]; then
    if [[ "$RESTART" == "true" ]]; then
        echo "==> Restarting process..."
    else
        echo "==> Stopping running process due to changes..."
    fi
    
    # Get initial log size/position
    if [[ -f "$LOG_FILE" ]]; then
        INITIAL_LOG_SIZE=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    else
        INITIAL_LOG_SIZE=0
    fi
    
    pkill -TERM -f "spotupnp-.*-static" || true
    
    # Monitor log file for shutdown progress
    MAX_WAIT=5
    SHUTDOWN_COMPLETE=false
    echo "    Monitoring graceful shutdown (max $MAX_WAIT seconds)..."
    
    for i in $(seq 1 $MAX_WAIT); do
        # Check if process is still running
        if ! pgrep -f "spotupnp-.*-static" > /dev/null; then
            echo "    Process stopped"
            SHUTDOWN_COMPLETE=true
            break
        fi
        
        # Check log file for shutdown completion marker
        if [[ -f "$LOG_FILE" ]]; then
            # Look for the final shutdown message
            if tail -n 20 "$LOG_FILE" 2>/dev/null | grep -q "terminate main thread"; then
                echo "    Clean shutdown sequence completed"
                # Wait a moment for process to actually exit
                sleep 0.5
                if ! pgrep -f "spotupnp-.*-static" > /dev/null; then
                    SHUTDOWN_COMPLETE=true
                    break
                fi
            # Check for shutdown activity
            elif tail -n 10 "$LOG_FILE" 2>/dev/null | grep -q -i "Stop:\|terminate.*thread\|flush renderers\|player thread exited\|deletion pending"; then
                echo "    Shutdown in progress..."
            fi
        fi
        
        sleep 1
    done
    
    # Force kill if still running
    if ! pgrep -f "spotupnp-.*-static" > /dev/null; then
        if [[ "$SHUTDOWN_COMPLETE" == "true" ]]; then
            echo "    Process shut down cleanly"
        fi
    else
        echo "    Process still running, sending SIGKILL..."
        pkill -KILL -f "spotupnp-.*-static" || true
        sleep 1
        echo "    Process forcefully terminated"
    fi
    echo ""
fi

# Decide whether to rebuild
SHOULD_REBUILD=false
if [[ "$SOURCE_CHANGED" == "true" ]]; then
    echo "==> Rebuild required due to source changes"
    SHOULD_REBUILD=true
elif [[ "$BINARY_EXISTS" == "false" ]]; then
    echo "==> Rebuild required - binary does not exist"
    SHOULD_REBUILD=true
else
    echo "==> Skipping rebuild - no source changes and binary exists"
fi

echo ""

if [[ "$SHOULD_REBUILD" == "true" ]]; then
    # Build updates
    echo "==> Building updates..."
    cd "$BUILD_DIR"
    
    if [[ "$CLEAN_BUILD" == "true" ]]; then
        echo "    Performing clean build..."
        if bash build.sh $PLATFORM static clean; then
            echo "    Clean build successful"
        else
            echo "    Build failed!"
            exit 1
        fi
    else
        if bash build.sh $PLATFORM static; then
            echo "    Build successful"
        else
            echo "    Build failed!"
            exit 1
        fi
    fi

    echo ""

    # Re-scan for binary after build
    FOUND_BINARIES=($(find "$BUILD_DIR/build" -maxdepth 2 -type f -name "spotupnp-*$PLATFORM-static" 2>/dev/null))
    
    if [[ ${#FOUND_BINARIES[@]} -eq 0 ]]; then
        echo "ERROR: Binary not found after build for platform: $PLATFORM"
        echo "       Searched in: $BUILD_DIR/build"
        exit 1
    elif [[ ${#FOUND_BINARIES[@]} -eq 1 ]]; then
        BINARY_PATH="${FOUND_BINARIES[0]}"
        BINARY_NAME="$(basename "$BINARY_PATH")"
        BUILD_OUTPUT_DIR="$(dirname "$BINARY_PATH")"
        echo "    Binary located: $BINARY_NAME"
    else
        echo "ERROR: Multiple binaries found for platform $PLATFORM:"
        for bin in "${FOUND_BINARIES[@]}"; do
            echo "      - $(basename "$bin")"
        done
        exit 1
    fi
else
    # Verify binary still exists
    if [[ ! -f "$BINARY_PATH" ]]; then
        echo "ERROR: Binary not found: $BINARY_PATH"
        echo "       Run with 'force' argument to rebuild"
        exit 1
    fi
fi

# Create spotconnect directory (ensure it exists before running)
echo "==> Preparing runtime environment..."
mkdir -p "$SPOTCONNECT_DIR"
echo "    Created: $SPOTCONNECT_DIR"

# Save current config hash for next run
if [[ -f "$CONFIG_FILE" && -n "$CURRENT_CONFIG_HASH" ]]; then
    echo "$CURRENT_CONFIG_HASH" > "$CONFIG_HASH_FILE"
    echo "    Saved config hash for next comparison"
fi

# Save current source hash for next run (if we built or verified sources)
if [[ -n "$CURRENT_SOURCE_HASH" ]]; then
    echo "$CURRENT_SOURCE_HASH" > "$SOURCE_HASH_FILE"
    echo "    Saved source hash for next comparison"
fi

# Save binary path for crash analysis tools
if [[ -n "$BINARY_PATH" && -f "$BINARY_PATH" ]]; then
    echo "$BINARY_PATH" > "$BINARY_PATH_FILE"
fi

echo ""

# Run updated version
echo "==> Starting $BINARY_NAME..."
echo "    Config: $CONFIG_FILE"
echo "    Log file: $LOG_FILE (stdout + stderr)"
echo "    Working directory: $(dirname "$BINARY_PATH")"
echo "    Mode: Background (daemonized)"
echo ""
echo "========================================"
echo ""

cd "$(dirname "$BINARY_PATH")"

# Ensure previous process logs are flushed
# Wait a moment after process termination to let file handles close
if [[ "$PROCESS_RUNNING" == "true" && ("$SOMETHING_CHANGED" == "true" || "$RESTART" == "true") ]]; then
    sleep 0.5
    sync  # Force all buffered writes to disk
fi

# Write banner to log file with clear separation from previous logs
# Reset color before banner without visible text
{
    echo -e "\033[0m"
    echo ""
    echo ""
    echo "================================================================================"
    echo "  SPOTCONNECT START - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================================"
    echo "  Binary:  $BINARY_NAME"
    echo "  Config:  $CONFIG_FILE"
    echo "  Started: $(date '+%A, %B %d, %Y at %H:%M:%S %Z')"
    echo "  Host:    $(hostname)"
    echo "================================================================================"
    echo ""
} >> "$LOG_FILE"

# Redirect both stdout and stderr to log file
"./$BINARY_NAME" -z -x "$CONFIG_FILE" -f "$LOG_FILE" >> "$LOG_FILE" 2>&1

# Give it a moment to start
sleep 2

# Check if process started successfully
if pgrep -f "spotupnp-.*-static" > /dev/null; then
    echo ""
    echo "==> Process started successfully in background"
    echo "    Binary: $BINARY_NAME"
    echo "    View logs: tail -f $LOG_FILE"
    echo "    Stop process: pkill -TERM -f 'spotupnp-.*-static'"
else
    echo ""
    echo "ERROR: Process failed to start. Check log file:"
    echo "       tail $LOG_FILE"
    exit 1
fi
