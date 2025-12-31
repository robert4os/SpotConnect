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
LOGTHIS_FILE="$BUILD_DIR/dev-run/logthis.log"
CLEAN_BUILD=false
RESTART=false
KILL_ONLY=false
BUILD_ONLY=false

# Enable core dumps for development/debugging
ulimit -c unlimited
echo ""  
echo "==> Dev-Run: Development Build & Run Environment"
echo "    Core dumps enabled (ulimit -c unlimited)"
echo ""

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
        --kill)
            KILL_ONLY=true
            shift
            ;;
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
            echo "Usage: $0 [--platform <arch>] [--clean] [--restart] [--kill] [--build-only]"
            echo "  --platform <arch> : Target platform architecture (default: x86_64)"
            echo "  --clean           : Perform clean build (removes build directory)"
            echo "  --restart         : Restart process regardless of changes"
            echo "  --kill            : Only kill the current binary (no build/restart)"
            echo "  --build-only      : Only compile if code changed (no process management)"
            echo ""
            echo "Examples:"
            echo "  $0                        # Use default platform (x86_64)"
            echo "  $0 --platform armv7       # Build for ARM v7"
            echo "  $0 --clean --restart      # Clean build and restart"
            echo "  $0 --kill                 # Just kill the running process"
            echo "  $0 --build-only           # Only compile if changed (no run)"
            exit 1
            ;;
    esac
done

# Derive platform-dependent paths
# Scan for binary in build directories
echo "==> Binary Detection"
echo "    Platform: $PLATFORM"
FOUND_BINARIES=($(find "$BUILD_DIR/build" -maxdepth 2 -type f -name "spotupnp-*$PLATFORM-static" 2>/dev/null))

if [[ ${#FOUND_BINARIES[@]} -eq 0 ]]; then
    echo "    Status: Not found (will build)"
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
    echo "    Status: Found"
    echo "    Binary: $BINARY_NAME"
    echo "    Location: $BUILD_OUTPUT_DIR"
else
    echo "    ERROR: Multiple binaries found for platform $PLATFORM:"
    for bin in "${FOUND_BINARIES[@]}"; do
        echo "      - $(basename "$bin") in $(dirname "$bin")"
    done
    exit 1
fi
echo ""

# Display script mode
echo "==> Execution Mode"
if [[ "$CLEAN_BUILD" == "true" && "$RESTART" == "true" ]]; then
    echo "    CLEAN BUILD + RESTART"
elif [[ "$CLEAN_BUILD" == "true" ]]; then
    echo "    CLEAN BUILD"
elif [[ "$RESTART" == "true" ]]; then
    echo "    RESTART"
else
    echo "    NORMAL (use --clean or --restart for special modes)"
fi
echo ""

# Check if ANY spotupnp binary process is running (platform-agnostic)
# Check actual executable via /proc filesystem to distinguish from viewers
echo "==> Process Status"
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
            echo "    Running: $(basename "$RUNNING_BINARY")"
            echo "    PID: $pid"
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
    echo "    Running: No"
fi

echo ""

# Handle --kill argument
if [[ "$KILL_ONLY" == "true" ]]; then
    if [[ "$PROCESS_RUNNING" == "false" ]]; then
        echo "==> Kill Mode: No process to kill"
        exit 0
    fi
    
    echo "==> Kill Mode: Stopping process..."
    
    # Get initial log size/position
    if [[ -f "$LOG_FILE" ]]; then
        INITIAL_LOG_SIZE=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    else
        INITIAL_LOG_SIZE=0
    fi
    
    pkill -TERM -f "spotupnp-.*-static" || true
    
    # Monitor log file for shutdown progress
    MAX_WAIT=10
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
    echo "==> Done"
    exit 0
fi


# Create spotconnect directory early to store hash file
mkdir -p "$SPOTCONNECT_DIR"

# Check if config file exists, if not create it
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "==> Configuration Setup"
    echo "    Config file not found: $CONFIG_FILE"
    
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
echo "==> Configuration Change Detection"
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
            echo "    Config unchanged"
        fi
    else
        echo "    First run - no previous config hash"
        CONFIG_CHANGED=true
    fi
else
    echo "    WARNING: Config file not found: $CONFIG_FILE"
fi

echo ""

# Check if the source code has been changed using git
echo "==> Source Code Change Detection (git)"
cd "$BUILD_DIR"
SOURCE_CHANGED=false

# Find all git repositories in the spotconnect tree (deterministic order)
SPOTCONNECT_ROOT="$(cd "$BUILD_DIR/.." && pwd)"
CURR_STATE_FILE="$SPOTCONNECT_DIR/.curr_git_state"

# Build a sorted list of all modified files with their git hash
# Format: repo_name|status|filepath|git_hash
{
    find "$SPOTCONNECT_ROOT" -name ".git" \( -type d -o -type f \) 2>/dev/null | while read git_marker; do
        repo_path="$(dirname "$git_marker")"
        repo_name="$(realpath --relative-to="$SPOTCONNECT_ROOT" "$repo_path" 2>/dev/null || basename "$repo_path")"
        
        # Get all modified files (staged and unstaged), excluding dev-run
        git -C "$repo_path" status --porcelain 2>/dev/null | grep -v "dev-run/" | while read status file; do
            # For existing files, get git's content hash; for deleted/new, use special markers
            file_path="$repo_path/$file"
            if [[ -f "$file_path" ]]; then
                # Use git hash-object to get deterministic content hash
                git_hash=$(git -C "$repo_path" hash-object "$file" 2>/dev/null || echo "error")
            elif [[ "$status" == "D"* ]]; then
                git_hash="deleted"
            else
                git_hash="new"
            fi
            echo "$repo_name|$status|$file|$git_hash"
        done
    done
} | sort > "$CURR_STATE_FILE"

# Calculate overall hash from all modified files
CURRENT_SOURCE_HASH=$(cat "$CURR_STATE_FILE" | md5sum | awk '{print $1}')

if [[ -f "$SOURCE_HASH_FILE" ]]; then
    PREVIOUS_SOURCE_HASH=$(cat "$SOURCE_HASH_FILE")
    
    if [[ "$CURRENT_SOURCE_HASH" != "$PREVIOUS_SOURCE_HASH" ]]; then
        PREV_STATE_FILE="$SPOTCONNECT_DIR/.prev_git_state"
        
        if [[ -f "$PREV_STATE_FILE" ]]; then
            # Show only NEW changes (files that are new or have different content hash)
            NEW_CHANGES=$(comm -13 "$PREV_STATE_FILE" "$CURR_STATE_FILE")
            if [[ -n "$NEW_CHANGES" ]]; then
                echo "    New changes since last build:"
                echo "$NEW_CHANGES" | while IFS='|' read repo_name status file git_hash; do
                    echo "      [$repo_name] $status $file"
                done
                echo "    Source code changes detected - rebuild required"
                SOURCE_CHANGED=true
            else
                # Hash changed but no new changes - likely due to commits
                echo "    Git state changed (files committed/reverted) but no new code changes"
                echo "    No rebuild required"
            fi
        else
            # First build with changes - show all modified files
            echo "    All uncommitted changes:"
            cat "$CURR_STATE_FILE" | while IFS='|' read repo_name status file git_hash; do
                echo "      [$repo_name] $status $file"
            done
            echo "    Source code changes detected - rebuild required"
            SOURCE_CHANGED=true
        fi
    else
        echo "    No source changes detected since last build"
    fi
else
    echo "    First build - no previous source hash found"
    SOURCE_CHANGED=true
fi
# v2
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

# If restart or clean build flag is set, we'll always proceed
if [[ "$RESTART" == "true" || "$CLEAN_BUILD" == "true" ]]; then
    if [[ "$PROCESS_RUNNING" == "false" ]]; then
        if [[ "$RESTART" == "true" ]]; then
            echo "==> Restart requested, but no process running"
        else
            echo "==> Clean build requested, but no process running"
        fi
        echo "    Will start the process..."
    fi
    # Continue to handle process killing and starting below
elif [[ "$SOMETHING_CHANGED" == "false" && "$PROCESS_RUNNING" == "true" ]]; then
    # If nothing changed and process is running (and not restart/clean), abort
    # Clear log file before exiting (process keeps running)
    echo "==> Clearing Logs"
    echo "    Log file: $LOG_FILE"
    > "$LOG_FILE"
    [[ -f "$LOGTHIS_FILE" ]] && rm "$LOGTHIS_FILE"
    echo ""
    
    echo "========================================="
    echo "  No Action Needed"  
    echo "========================================="
    echo "  Source code : unchanged"
    echo "  Config file : unchanged"
    echo "  Process     : running"
    echo ""
    echo "Everything is up to date."
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
        echo "==> Stopping Process (restart requested)"
    else
        echo "==> Stopping Process (changes detected)"
    fi
    
    # Get initial log size/position
    if [[ -f "$LOG_FILE" ]]; then
        INITIAL_LOG_SIZE=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
    else
        INITIAL_LOG_SIZE=0
    fi
    
    pkill -TERM -f "spotupnp-.*-static" || true
    
    # Monitor log file for shutdown progress
    MAX_WAIT=10
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
if [[ "$CLEAN_BUILD" == "true" ]]; then
    echo "==> Build Decision: Rebuild Required"
    echo "    Reason: Clean build requested (--clean flag)"
    SHOULD_REBUILD=true
elif [[ "$SOURCE_CHANGED" == "true" ]]; then
    echo "==> Build Decision: Rebuild Required"
    echo "    Reason: Source code changed"
    SHOULD_REBUILD=true
elif [[ "$BINARY_EXISTS" == "false" ]]; then
    echo "==> Build Decision: Rebuild Required"
    echo "    Reason: Binary does not exist"
    SHOULD_REBUILD=true
else
    echo "==> Build Decision: Skip Rebuild"
    echo "    Binary exists and source unchanged"
fi

echo ""

if [[ "$SHOULD_REBUILD" == "true" ]]; then
    # Build updates
    echo "==> Building"
    cd "$BUILD_DIR"
    
    if [[ "$CLEAN_BUILD" == "true" ]]; then
        echo "    Mode: Clean build (removing build directory)"
        # Remove entire build directory to force CMake regeneration
        if [[ -d "$BUILD_DIR/build" ]]; then
            rm -rf "$BUILD_DIR/build"
            echo "    Removed: $BUILD_DIR/build"
        fi
        if bash build.sh $PLATFORM static; then
            echo "    ✓ Clean build successful"
        else
            echo "    ✗ Build failed!"
            exit 1
        fi
    else
        if bash build.sh $PLATFORM static; then
            echo "    ✓ Build successful"
        else
            echo "    ✗ Build failed!"
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
echo "==> Runtime Preparation"
mkdir -p "$SPOTCONNECT_DIR"
echo "    Directory: $SPOTCONNECT_DIR"

# Remove old crash file from previous session
if [[ -f "/tmp/spotupnp-crash-latest.txt" ]]; then
    rm -f "/tmp/spotupnp-crash-latest.txt"
    echo "    Removed old crash dump"
fi

# Check and report core dump status
CORE_LIMIT=$(ulimit -c)
CORE_PATTERN=$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo "unknown")
echo "    Core dumps: enabled (limit: $CORE_LIMIT)"
echo "    Core pattern: $CORE_PATTERN"
if [[ "$CORE_PATTERN" == *"|"* ]]; then
    echo "    Note: Cores piped to crash handler (WSL), check /tmp for captured cores"
fi

# Save current config hash for next run
if [[ -f "$CONFIG_FILE" && -n "$CURRENT_CONFIG_HASH" ]]; then
    echo "$CURRENT_CONFIG_HASH" > "$CONFIG_HASH_FILE"
    echo "    Saved config hash for next comparison"
fi

# Save current source hash for next run (if we built or verified sources)
if [[ -n "$CURRENT_SOURCE_HASH" ]]; then
    echo "$CURRENT_SOURCE_HASH" > "$SOURCE_HASH_FILE"
    echo "    Saved source hash for next comparison"
    
    # Also save the current git state for incremental change detection
    CURR_STATE_FILE="$SPOTCONNECT_DIR/.curr_git_state"
    PREV_STATE_FILE="$SPOTCONNECT_DIR/.prev_git_state"
    if [[ -f "$CURR_STATE_FILE" ]]; then
        mv "$CURR_STATE_FILE" "$PREV_STATE_FILE"
    fi
fi

# Save binary path for crash analysis tools
if [[ -n "$BINARY_PATH" && -f "$BINARY_PATH" ]]; then
    echo "$BINARY_PATH" > "$BINARY_PATH_FILE"
fi

# If --build-only mode, we're done - don't start the process
if [[ "$BUILD_ONLY" == "true" ]]; then
    echo ""
    echo "========================================="
    echo "Build-only mode: Compilation complete"
    echo "========================================="
    echo "  Binary: $BINARY_NAME"
    echo "  Location: $BUILD_OUTPUT_DIR"
    echo ""
    echo "Process NOT started (--build-only mode)"
    exit 0
fi

GDB_LOG="$SPOTCONNECT_DIR/gdb-crash.log"
GDB_COMMANDS="$SPOTCONNECT_DIR/.gdb-commands"

# Create command file that loops waiting for crashes
cat > "$GDB_COMMANDS" << 'GDBCMD'
set pagination off
set confirm off
set print pretty on
set logging file ~/.spotconnect/gdb-crash.log
set logging overwrite on

# Suppress verbose GDB output
set print thread-events off
set print inferior-events off

# Follow child process after fork (this is where the crash happens!)
set follow-fork-mode child
set detach-on-fork on

handle SIGSEGV stop print nopass
handle SIGABRT stop print nopass
handle SIGILL stop print nopass
handle SIGFPE stop print nopass
handle SIGBUS stop print nopass
handle SIGPIPE nostop noprint pass
handle SIGTERM nostop noprint pass

run -z -x $HOME/dev/spotconnect/spotupnp/dev-run/config.xml -f ~/.spotconnect/spotupnp.log

# Only log crash info if program stopped due to a signal (not normal exit)
# Check if we have a valid inferior and it was signaled
python
import gdb
try:
    inferior = gdb.selected_inferior()
    threads = inferior.threads()
    if threads and gdb.selected_thread() and gdb.selected_thread().is_valid():
        # Program stopped abnormally (signal), proceed with crash logging
        gdb.execute("set logging enabled on")
        gdb.execute("echo \\n================================================================================\\n")
        gdb.execute("echo === CRASH DETECTED (Signal) ===\\n")
        gdb.execute("echo ================================================================================\\n")
        gdb.execute("where")
        gdb.execute("echo \\n=== BACKTRACE WITH LOCALS ===\\n")
        gdb.execute("backtrace full")
        gdb.execute("echo \\n=== FRAME INFO ===\\n")
        gdb.execute("info frame")
        gdb.execute("info args")
        gdb.execute("info locals")
        gdb.execute("echo \\n=== MEMORY AT CRASH SITE ===\\n")
        gdb.execute("x/32xb $rip")
        gdb.execute("x/8xg $rsp")
        gdb.execute("echo \\n=== HEAP INFO (if available) ===\\n")
        gdb.execute("info proc mappings")
        gdb.execute("echo \\n=== DETAILED FRAME ANALYSIS ===\\n")
        gdb.execute("frame 0")
        gdb.execute("info frame")
        gdb.execute("info args")
        gdb.execute("info locals")
        gdb.execute("x/16xg $rbp-64")
        gdb.execute("x/16xg $rsp")
        gdb.execute("echo \\n=== ALL THREADS ===\\n")
        gdb.execute("info threads")
        gdb.execute("thread apply all backtrace")
        gdb.execute("echo \\n=== REGISTERS ===\\n")
        gdb.execute("info registers")
        gdb.execute("echo \\n=== SHARED LIBRARIES ===\\n")
        gdb.execute("info sharedlibrary")
        gdb.execute("echo \\n=== TRY TO SAVE CORE DUMP ===\\n")
        gdb.execute("generate-core-file ~/.spotconnect/core-crash")
        gdb.execute("echo \\n================================================================================\\n")
        gdb.execute("set logging enabled off")
except:
    # No valid inferior or normal exit
    pass
end

quit
GDBCMD

if [[ -f "$GDB_LOG" ]]; then
    rm -f "$GDB_LOG"
    echo "    Removed old GDB crash log"
fi

echo ""

# Run updated version
echo "==> Starting Application"
echo "    Binary: $BINARY_NAME"
echo "    Config: $CONFIG_FILE"
echo "    Log file: $LOG_FILE"
echo "    GDB log: $GDB_LOG"
echo "    Working dir: $(dirname "$BINARY_PATH")"
echo "    Mode: Development (GDB with crash detection)"
echo ""

cd "$(dirname "$BINARY_PATH")"

# Ensure previous process logs are flushed
# Wait a moment after process termination to let file handles close
if [[ "$PROCESS_RUNNING" == "true" && ("$SOMETHING_CHANGED" == "true" || "$RESTART" == "true") ]]; then
    sleep 0.5
    sync  # Force all buffered writes to disk
fi

# Clear log file right before starting (keeps same inode for tail -f compatibility)
echo "    Clearing log file: $LOG_FILE"
> "$LOG_FILE"
[[ -f "$LOGTHIS_FILE" ]] && rm "$LOGTHIS_FILE"

# Clear any temporary files from previous runs (truncate to keep inode for tail -f)
if ls /tmp/spotupnp* 1> /dev/null 2>&1; then
    echo "    Clearing temp files: /tmp/spotupnp*"
    for file in /tmp/spotupnp*; do
        > "$file"
    done
fi

# Write banner to log file with clear separation from previous logs
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

# Run under GDB - commands after run only execute if program stops abnormally
echo "    Starting program under GDB in background..."

# Enable unbuffered logging for development (forces fflush after each log line)
export CSPOT_UNBUFFERED=1

# Enable debug file logging for cspot component
export CSPOT_DEBUG_FILES=1

# Disable shell buffering: -i0 = unbuffered stdin, -o0 = unbuffered stdout, -e0 = unbuffered stderr
stdbuf -i0 -o0 -e0 gdb -q -x "$GDB_COMMANDS" "./$BINARY_NAME" >> "$LOG_FILE" 2>&1 &

GDB_PID=$!

# Give it a moment to start
sleep 2
echo ""

# Check if the actual binary process is running (not just GDB wrapper)
if pgrep -f "spotupnp-.*-static" > /dev/null; then
    ACTUAL_PID=$(pgrep -f "spotupnp-.*-static")
    echo "==> Status: Running"
    echo "    Process PID: $ACTUAL_PID"
    echo "    GDB wrapper PID: $GDB_PID"
    echo ""
    echo "==> Monitor & Control"
    echo "    View logs: tail -f $LOG_FILE"
    echo "    Stop: pkill -TERM -f 'spotupnp-.*-static'"
else
    echo "==> Status: Failed to Start"
    echo "    Check logs: tail $LOG_FILE"
    if [[ -f "$GDB_LOG" ]]; then
        echo "    Crash log: $GDB_LOG"
    fi
    exit 1
fi
