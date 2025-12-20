#!/bin/bash

# Crash Analysis Script for spotupnp
# Automatically analyzes crash dumps and provides debugging information

set -euo pipefail

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

# Check if a specific crash file was provided
if [ $# -gt 0 ]; then
    CRASH_FILE="$1"
    if [ ! -f "$CRASH_FILE" ]; then
        echo -e "${COLOR_RED}Error: Crash file not found: $CRASH_FILE${COLOR_RESET}"
        exit 1
    fi
else
    # Find most recent crash dump
    CRASH_FILE=$(ls -t /tmp/spotupnp-crash-*.txt 2>/dev/null | head -1)
    if [ -z "$CRASH_FILE" ]; then
        echo -e "${COLOR_YELLOW}No crash dump files found in /tmp/${COLOR_RESET}"
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
        exit 0
    fi
fi

echo -e "Analyzing: ${COLOR_GREEN}$CRASH_FILE${COLOR_RESET}"
echo ""

# Display crash info
echo -e "${COLOR_YELLOW}=== Crash Information ===${COLOR_RESET}"
head -20 "$CRASH_FILE"
echo ""

# Extract and decode stack trace addresses
echo -e "${COLOR_YELLOW}=== Decoded Stack Trace ===${COLOR_RESET}"

# Check if binary has symbols
HAS_SYMBOLS=false
if nm "$BINARY" 2>/dev/null | head -1 | grep -q .; then
    HAS_SYMBOLS=true
    echo -e "${COLOR_GREEN}Binary has symbols - decoding addresses...${COLOR_RESET}"
    echo ""
    
    # Extract addresses from backtrace and decode them
    grep -oP '\[0x[0-9a-f]+\]' "$CRASH_FILE" | while read -r addr; do
        addr=${addr#[}
        addr=${addr%]}
        
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

ULIMIT_CORE=$(ulimit -c)
if [ "$ULIMIT_CORE" = "0" ]; then
    echo -e "${COLOR_RED}Core dumps are DISABLED (ulimit -c = 0)${COLOR_RESET}"
    echo "To enable: ulimit -c unlimited"
else
    echo -e "${COLOR_GREEN}Core dumps are enabled (limit: $ULIMIT_CORE)${COLOR_RESET}"
    
    # Look for core files
    CORE_FILES=$(find /tmp -name "core.*" -o -name "core.spotupnp*" 2>/dev/null | head -5)
    if [ -n "$CORE_FILES" ]; then
        echo ""
        echo "Found core dumps:"
        echo "$CORE_FILES"
        echo ""
        echo "To analyze with GDB:"
        echo "  gdb $BINARY <core_file>"
        echo "  (gdb) bt full"
    fi
fi
echo ""

# Suggest next steps
echo -e "${COLOR_BLUE}=== Next Steps ===${COLOR_RESET}"
echo "1. Review the decoded stack trace above"
echo "2. Check the crash dump file: $CRASH_FILE"
echo "3. Review kernel log: dmesg | grep spotupnp"
if [ "$ULIMIT_CORE" = "0" ]; then
    echo "4. Enable core dumps: ulimit -c unlimited"
fi
echo ""
echo "For detailed analysis with GDB:"
echo "  gdb $BINARY"
echo "  (gdb) run -x <config.xml>"
echo "  (when it crashes)"
echo "  (gdb) bt full"
echo "  (gdb) info registers"
echo "  (gdb) list"
echo ""
