#!/bin/bash

# Crash Analysis Script for spotupnp
# Automatically analyzes crash dumps and provides debugging information

set -uo pipefail  # Removed -e to allow grep failures

COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

echo -e "${COLOR_BLUE}================================${COLOR_RESET}"
echo -e "${COLOR_BLUE}spotupnp Crash Analysis Tool${COLOR_RESET}"
echo -e "${COLOR_BLUE}================================${COLOR_RESET}"
echo ""

# Read binary path from build.sh state file
SPOTCONNECT_DIR="$HOME/.spotconnect"
BINARY_PATH_FILE="$SPOTCONNECT_DIR/.binary_path"

if [ ! -f "$BINARY_PATH_FILE" ]; then
    echo -e "${COLOR_RED}Error: Binary path state file not found${COLOR_RESET}"
    echo "Expected: $BINARY_PATH_FILE"
    echo ""
    echo "Run dev-run/build.sh first to build and register the binary"
    exit 1
fi

BINARY=$(cat "$BINARY_PATH_FILE")

if [ ! -f "$BINARY" ]; then
    echo -e "${COLOR_RED}Error: Binary not found at registered path${COLOR_RESET}"
    echo "Expected: $BINARY"
    echo ""
    echo "Run dev-run/build.sh to rebuild the binary"
    exit 1
fi
echo -e "Binary: ${COLOR_GREEN}$BINARY${COLOR_RESET}"
echo ""

# Check for GDB crash log first (more detailed)
GDB_LOG="$SPOTCONNECT_DIR/gdb-crash.log"

if [ -f "$GDB_LOG" ]; then
    echo -e "${COLOR_GREEN}Found GDB crash artifacts: $GDB_LOG${COLOR_RESET}"
    echo ""
    
    echo -e "${COLOR_YELLOW}=== GDB Crash Capture ===${COLOR_RESET}"
    
    # Extract signal information
    if grep -q "Signal:" "$GDB_LOG"; then
        echo -e "${COLOR_RED}$(grep "Signal:" "$GDB_LOG")${COLOR_RESET}"
        echo ""
    fi
    
    # Show backtrace section
    if grep -q "=== BACKTRACE ===" "$GDB_LOG"; then
        echo -e "${COLOR_BLUE}=== Full Backtrace with Local Variables ===${COLOR_RESET}"
        sed -n '/=== BACKTRACE ===/,/=== REGISTERS ===/p' "$GDB_LOG" | head -100
        echo ""
    fi
    
    # Show register state
    if grep -q "=== REGISTERS ===" "$GDB_LOG"; then
        echo -e "${COLOR_BLUE}=== Register State ===${COLOR_RESET}"
        sed -n '/=== REGISTERS ===/,/=== THREADS ===/p' "$GDB_LOG" | head -50
        echo ""
    fi
    
    # Show thread information
    if grep -q "=== THREADS ===" "$GDB_LOG"; then
        echo -e "${COLOR_BLUE}=== Thread Information ===${COLOR_RESET}"
        sed -n '/=== THREADS ===/,$p' "$GDB_LOG" | head -100
        echo ""
    fi
    
    echo -e "${COLOR_GREEN}GDB artifacts analyzed successfully${COLOR_RESET}"
    echo "Full GDB log: $GDB_LOG"
    echo ""
fi

# Use fixed crash file location
CRASH_FILE="/tmp/spotupnp-crash-latest.txt"

# Check if a specific crash file was provided as argument (for debugging old crashes)
if [ $# -gt 0 ]; then
    CRASH_FILE="$1"
fi

if [ ! -f "$CRASH_FILE" ]; then
    echo -e "${COLOR_YELLOW}No custom crash dump found: $CRASH_FILE${COLOR_RESET}"
    
    # If we have GDB log, that's sufficient
    if [ -f "$GDB_LOG" ]; then
        echo "GDB crash artifacts already analyzed above (more detailed than crash handler)"
        echo ""
        # Continue to show logs at the end instead of exiting
    else
        echo "Looking for crashes in dmesg..."
        echo ""
        
        DMESG_OUT=$(dmesg | grep -i "spotupnp.*segfault\|spotupnp.*signal" | tail -5)
        if [ -n "$DMESG_OUT" ]; then
            echo -e "${COLOR_YELLOW}=== Recent crashes in kernel log ===${COLOR_RESET}"
            echo "$DMESG_OUT"
            echo ""
            
            # Extract address from most recent
            LAST_CRASH=$(echo "$DMESG_OUT" | tail -1)
            if echo "$LAST_CRASH" | grep -q "ip "; then
                IP_ADDR=$(echo "$LAST_CRASH" | grep -oP 'ip \K[0-9a-f]+')
                echo -e "${COLOR_GREEN}Attempting to decode crash address: 0x$IP_ADDR${COLOR_RESET}"
                echo ""
                addr2line -e "$BINARY" -f -C "0x$IP_ADDR" 2>/dev/null || echo "Could not decode (binary may be stripped)"
            fi
        else
            echo "No crashes found in dmesg either"
        fi
        echo ""
    fi
    
    # Show logs and exit
    LOG_FILE="$SPOTCONNECT_DIR/spotupnp.log"
    if [ -f "$LOG_FILE" ]; then
        echo -e "${COLOR_YELLOW}=== Last 15 Lines of Application Log ===${COLOR_RESET}"
        tail -15 "$LOG_FILE"
        echo ""
        echo "Full log: $LOG_FILE"
        echo ""
    fi
    
    exit 0
fi

echo -e "Analyzing: ${COLOR_GREEN}$CRASH_FILE${COLOR_RESET}"
echo -e "${COLOR_BLUE}(Custom crash handler output - GDB provides more detail above)${COLOR_RESET}"
echo ""

# Display crash info
echo -e "${COLOR_YELLOW}=== Crash Handler Output ===${COLOR_RESET}"
head -20 "$CRASH_FILE"
echo ""

# Extract and decode stack trace addresses
echo -e "${COLOR_YELLOW}=== Decoded Stack Trace ===${COLOR_RESET}"

# Check if binary has symbols - test by counting symbol lines
SYMBOL_COUNT=$(nm "$BINARY" 2>/dev/null | wc -l)
HAS_SYMBOLS=false

if [ "$SYMBOL_COUNT" -gt 10 ]; then
    HAS_SYMBOLS=true
    echo -e "${COLOR_GREEN}Binary has symbols ($SYMBOL_COUNT symbols found) - decoding addresses...${COLOR_RESET}"
    echo ""
    
    # Extract addresses from backtrace and decode them
    ADDRESSES=$(grep -oP '\[0x[0-9a-f]+\]' "$CRASH_FILE" | tr -d '[]')
    
    for addr in $ADDRESSES; do
        # Try to decode both function and line
        function_info=$(addr2line -e "$BINARY" -f "$addr" 2>/dev/null | head -1)
        location_info=$(addr2line -e "$BINARY" -C "$addr" 2>/dev/null | tail -1)
        
        if [ "$location_info" != "??:0" ] && [ "$location_info" != "??:?" ] && [ "$location_info" != "?" ]; then
            echo -e "${COLOR_GREEN}$addr${COLOR_RESET} -> ${COLOR_BLUE}$function_info${COLOR_RESET}"
            echo "        $location_info"
        else
            echo "$addr -> $function_info (location unknown)"
        fi
    done
    echo ""
else
    echo -e "${COLOR_YELLOW}Warning: Binary is stripped (no symbols available)${COLOR_RESET}"
    echo ""
fi

# Even without symbols, try to extract useful information
echo -e "${COLOR_BLUE}=== Additional Analysis ===${COLOR_RESET}"

# Extract fault address
FAULT_ADDR=$(grep -oP 'Fault Address: \K0x[0-9a-f]+' "$CRASH_FILE" || echo "unknown")
echo "Fault Address: $FAULT_ADDR"

if [ "$FAULT_ADDR" != "unknown" ]; then
    # Check if it's a null pointer dereference
    ADDR_DEC=$((FAULT_ADDR))
    if [ "$ADDR_DEC" -lt 4096 ]; then
        echo -e "${COLOR_RED}  ⚠ NULL pointer dereference (address < 4096)${COLOR_RESET}"
        echo "  This typically means dereferencing a null or near-null pointer"
    elif [ "$ADDR_DEC" -lt 65536 ]; then
        echo -e "${COLOR_YELLOW}  ⚠ Low memory address (possible struct member access on null pointer)${COLOR_RESET}"
        echo "  Offset: $ADDR_DEC bytes - check for struct->member where struct is NULL"
    fi
fi
echo ""

# Extract instruction pointer from dmesg if available
DMESG_CRASH=$(dmesg | grep "spotupnp.*segfault" | tail -1 || echo "")
if [ -n "$DMESG_CRASH" ]; then
    IP_ADDR=$(echo "$DMESG_CRASH" | grep -oP 'ip \K[0-9a-f]+' || echo "")
    ERROR_CODE=$(echo "$DMESG_CRASH" | grep -oP 'error \K[0-9]+' || echo "")
    
    if [ -n "$IP_ADDR" ]; then
        echo "Crash Instruction Pointer: 0x$IP_ADDR"
        
        # Decode error code
        if [ -n "$ERROR_CODE" ]; then
            echo -n "Error Code: $ERROR_CODE ("
            case "$ERROR_CODE" in
                4) echo -n "read from unmapped memory" ;;
                6) echo -n "write to unmapped memory" ;;
                5) echo -n "read protection fault" ;;
                7) echo -n "write protection fault" ;;
                *) echo -n "unknown error type" ;;
            esac
            echo ")"
        fi
        echo ""
    fi
fi

# Show binary information
echo -e "${COLOR_BLUE}=== Binary Information ===${COLOR_RESET}"
STRIP_STATUS=$(file "$BINARY" | grep -oP '(stripped|not stripped|with debug_info)' || echo "unknown")
echo "Strip status: $STRIP_STATUS"
echo "Size: $(ls -lh "$BINARY" | awk '{print $5}')"
BUILD_ID=$(readelf -n "$BINARY" 2>/dev/null | grep -A1 "Build ID" | tail -1 | xargs || echo "none")
echo "Build ID: $BUILD_ID"
echo ""

# Check build flags
if [ "$HAS_SYMBOLS" = "false" ]; then
    echo -e "${COLOR_YELLOW}=== To Enable Symbol Support ===${COLOR_RESET}"
    echo "The binary is stripped and has no debugging symbols."
    echo "To keep symbols for crash analysis:"
    echo "  1. Remove the -s flag from LDFLAGS in build.sh (already done)"
    echo "  2. Rebuild: cd spotupnp && ./build.sh x86_64 static clean"
    echo ""
else
    echo -e "${COLOR_GREEN}✓ Binary has debugging symbols${COLOR_RESET}"
    echo "Stack traces should be fully decoded above."
    echo ""
fi

# Show recent kernel messages
echo -e "${COLOR_YELLOW}=== Recent Kernel Messages (dmesg) ===${COLOR_RESET}"
dmesg | grep -i spotupnp | tail -10
echo ""

# Check for core dumps
echo -e "${COLOR_YELLOW}=== Core Dump Status ===${COLOR_RESET}"
CORE_PATTERN=$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo "unknown")
echo "Core pattern: $CORE_PATTERN"

# Note: build.sh sets ulimit when launching the process, so don't check current shell's ulimit
# Instead, look for actual core files
if [[ "$CORE_PATTERN" == *"|"* ]]; then
    echo "Note: Cores piped to crash handler (WSL): $(echo "$CORE_PATTERN" | cut -d'|' -f2 | awk '{print $1}')"
fi

# Look for core files in common locations
CORE_FILES=$(find /tmp -maxdepth 1 \( -name "core.*" -o -name "core" -o -name "*spotupnp*.core" -o -name "wsl-core-*" \) -type f -mtime -1 2>/dev/null)

if [ -n "$CORE_FILES" ]; then
    echo -e "${COLOR_GREEN}Found recent core dumps:${COLOR_RESET}"
    echo "$CORE_FILES" | while read -r core_file; do
        size=$(ls -lh "$core_file" 2>/dev/null | awk '{print $5}')
        mtime=$(stat -c '%y' "$core_file" 2>/dev/null | cut -d'.' -f1)
        echo "  $core_file ($size, $mtime)"
    done
    echo ""
    echo "To analyze with GDB:"
    echo "  gdb $BINARY <core_file>"
    echo "  (gdb) bt full"
else
    echo "No recent core dumps found in /tmp"
    echo "Note: build.sh enables cores when launching (ulimit -c unlimited)"
fi
echo ""

# Suggest next steps
echo -e "${COLOR_BLUE}=== Next Steps ===${COLOR_RESET}"
echo "1. Examine the source code at the crash location (see stack trace above)"
echo "2. Check for similar patterns in logs:"
echo "     grep -i 'error\|exception\|assert' ~/.spotconnect/spotupnp.log"
echo "3. Fix the issue and test with: cd ~/dev/spotconnect/spotupnp/dev-run && ./build.sh"
echo "   (Runs automatically under GDB with crash capture)"
echo ""

# Show last 15 lines of application log for context
LOG_FILE="$SPOTCONNECT_DIR/spotupnp.log"
if [ -f "$LOG_FILE" ]; then
    echo -e "${COLOR_YELLOW}=== Last 15 Lines of Application Log ===${COLOR_RESET}"
    tail -15 "$LOG_FILE"
    echo ""
    echo "Full log: $LOG_FILE"
    echo ""
fi
