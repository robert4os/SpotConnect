#!/bin/bash

# spircthis-analyze.sh - SPIRC Protocol Analysis Tool
# Analyzes SPIRC debug files to understand message flow and identify issues

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Required arguments
SPIRC_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --file)
            SPIRC_FILE="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown argument: $1"
            echo ""
            echo "Usage: $0 --file <spirc-file>"
            echo ""
            echo "Required:"
            echo "  --file <spirc-file>     Path to SPIRC debug file to analyze"
            exit 1
            ;;
    esac
done

# Validate required argument
if [[ -z "$SPIRC_FILE" ]]; then
    echo "Error: --file is required"
    echo ""
    echo "Usage: $0 --file <spirc-file>"
    exit 1
fi

if [[ ! -f "$SPIRC_FILE" ]]; then
    echo "Error: SPIRC debug file not found: $SPIRC_FILE"
    exit 1
fi

echo "============================================"
echo "  SPIRC PROTOCOL ANALYSIS"
echo "============================================"
echo "File: $SPIRC_FILE"
echo "Size: $(wc -l < "$SPIRC_FILE") lines"
echo ""

# Extract message flow with position information
echo "=== MESSAGE FLOW TIMELINE ==="
awk '
BEGIN {
    direction = ""
    type = ""
    status = ""
    frame_pos = ""
    state_pos = ""
    has_state_pos = ""
    timestamp = ""
}

/^=== INCOMING FRAME ===/ {
    if (direction != "") print_frame()
    direction = "→ IN"
    timestamp = substr($0, 23)
    next
}

/^=== OUTGOING FRAME ===/ {
    if (direction != "") print_frame()
    direction = "OUT→"
    timestamp = substr($0, 23)
    next
}

/^Message Type:/ {
    type = $3 " " $4
    next
}

/^Status:/ {
    status = $2
    next
}

/^Top-level Position \(frame\.position\):/ {
    # Field 4 is the number value
    frame_pos = $4
    next
}

/^Position:/ && !/Top-level/ && !/Measured/ {
    # Extract just the number, field 2 is the number
    state_pos = $2
    next
}

/^Has State:/ {
    has_state_pos = $3
    next
}

function print_frame() {
    # Format: direction | type | status | positions
    printf "%-4s | %-12s | %-15s | frame.pos=%-6s state.pos=%-8s | %s\n", 
           direction, type, status, frame_pos, state_pos, timestamp
    
    # Reset for next frame
    direction = ""
    type = ""
    status = ""
    frame_pos = ""
    state_pos = ""
    has_state_pos = ""
    timestamp = ""
}

END {
    if (direction != "") print_frame()
}
' "$SPIRC_FILE"

echo ""

# Count message types
echo "=== MESSAGE TYPE SUMMARY ==="
echo "Incoming messages:"
awk '/^=== INCOMING FRAME ===/{flag=1; next} /^=== OUTGOING FRAME ===/{flag=0} flag && /^Message Type:/{print $3 " " $4}' "$SPIRC_FILE" | sort | uniq -c | sed 's/^/  /'

echo ""
echo "Outgoing messages:"
awk '/^=== OUTGOING FRAME ===/{flag=1; next} /^=== INCOMING FRAME ===/{flag=0} flag && /^Message Type:/{print $3 " " $4}' "$SPIRC_FILE" | sort | uniq -c | sed 's/^/  /'

echo ""

# Position field analysis
echo "=== POSITION FIELD ANALYSIS ==="
echo "Checking if Spotify uses frame.position vs state.position_ms..."

# Check incoming Load frames
LOAD_COUNT=$(grep -c "^=== INCOMING FRAME ===" "$SPIRC_FILE" | awk 'BEGIN{c=0} /Message Type: Load/{getline; getline; getline; getline; getline; getline; if (/Top-level Position.*0 ms/) c++} END{print c}')

awk '
/^=== INCOMING FRAME ===/ {
    incoming = 1
    outgoing = 0
    msg_type = ""
    frame_pos = ""
    state_pos = ""
    next
}

/^=== OUTGOING FRAME ===/ {
    incoming = 0
    outgoing = 1
    next
}

incoming && /^Message Type: (Load|Seek)/ {
    msg_type = $3
    next
}

incoming && /^Top-level Position/ {
    frame_pos = $4
    next
}

incoming && /^Position:/ && !/Top-level/ && !/Measured/ {
    state_pos = $2
    if (msg_type == "Load" || msg_type == "Seek") {
        print "  " msg_type ": frame.position=" frame_pos " ms, state.position_ms=" state_pos " ms"
        if (frame_pos == "0" && state_pos != "0") {
            print "    ✓ Spotify is using state.position_ms (frame.position is 0)"
        } else if (frame_pos != "0" && state_pos == "0") {
            print "    ⚠ Spotify is using frame.position (state.position_ms is 0)"
        } else if (frame_pos != "0" && state_pos != "0") {
            print "    ⚠ Both fields set (frame.position=" frame_pos ", state.position_ms=" state_pos ")"
        }
    }
    msg_type = ""
    frame_pos = ""
    state_pos = ""
}
' "$SPIRC_FILE"

echo ""

# Detect position jumps (takeover scenarios)
echo "=== PLAYBACK TAKEOVER ANALYSIS ==="
awk '
BEGIN {
    prev_pos = 0
    prev_type = ""
    takeover = 0
}

/^=== INCOMING FRAME ===/ {
    direction = "IN"
    next
}

/^Message Type: Load/ {
    if (direction == "IN") {
        takeover = 1
        msg_type = "Load"
    }
    next
}

/^Position:/ && !/Top-level/ && !/Measured/ {
    pos = $2
    gsub(" ms", "", pos)
    
    if (takeover && direction == "IN") {
        if (pos > 5000) {
            print "  Mid-song takeover detected:"
            print "    Load command at position: " pos " ms (" pos/1000 " seconds)"
            print "    ✓ Player should start playback at this position"
        } else {
            print "  Start-of-song takeover:"
            print "    Load command at position: " pos " ms"
        }
        takeover = 0
    }
    
    prev_pos = pos
    direction = ""
}
' "$SPIRC_FILE"

echo ""

# Check for common issues
echo "=== ISSUE DETECTION ==="

# Check if position field mismatch could cause issues
POSITION_ZERO_COUNT=$(awk '/^=== INCOMING FRAME ===/{flag=1; next} /^=== OUTGOING FRAME ===/{flag=0} flag && /^Message Type: Load/{load=1} load && /^Top-level Position.*0 ms/{count++} /^Position:/ && !/Top-level/{load=0} END{print count+0}' "$SPIRC_FILE")

if [ "$POSITION_ZERO_COUNT" -gt 0 ]; then
    echo "  ✓ Detected Load frames with frame.position=0"
    echo "    This is normal - Spotify uses state.position_ms"
    echo "    Code should use getPositionFromFrame() fallback method"
else
    echo "  ℹ No Load frames with frame.position=0 detected"
fi

# Check for rapid position changes
echo ""
awk '
BEGIN {
    prev_out_pos = -1
    rapid_changes = 0
}

/^=== OUTGOING FRAME ===/ {
    outgoing = 1
    next
}

/^=== INCOMING FRAME ===/ {
    outgoing = 0
    next
}

outgoing && /^Position:/ && !/Top-level/ && !/Measured/ {
    pos = $2
    gsub(" ms", "", pos)
    
    if (prev_out_pos >= 0) {
        diff = pos - prev_out_pos
        if (diff < -1000) {
            rapid_changes++
            print "  ⚠ Position jump backward: " prev_out_pos " ms → " pos " ms (Δ " diff " ms)"
        } else if (diff > 30000) {
            rapid_changes++
            print "  ⚠ Position jump forward: " prev_out_pos " ms → " pos " ms (Δ " diff " ms)"
        }
    }
    
    prev_out_pos = pos
}

END {
    if (rapid_changes == 0) {
        print "  ✓ No unusual position jumps detected"
    }
}
' "$SPIRC_FILE"

echo ""

# Device information
echo "=== DEVICE INFORMATION ==="
awk '
/^Device ID:/ {
    if (!seen[$0]++) {
        device_id = substr($0, 12)
        print "  " $0
    }
    next
}

/^Device Name:/ {
    if (!seen[$0]++) print "  " $0
    next
}

/^Protocol Version:/ {
    if (!seen[$0]++) print "  " $0
    next
}
' "$SPIRC_FILE"

echo ""

# Status transitions
echo "=== PLAYBACK STATUS TRANSITIONS ==="
awk '
BEGIN {
    prev_status = ""
    direction = ""
}

/^=== INCOMING FRAME ===/ {
    direction = "→ IN"
    next
}

/^=== OUTGOING FRAME ===/ {
    direction = "OUT→"
    next
}

/^Status:/ {
    status = $2
    if (status != prev_status && prev_status != "") {
        print "  " direction ": " prev_status " → " status
    }
    prev_status = status
}
' "$SPIRC_FILE"

echo ""

echo "============================================"
echo "  ANALYSIS COMPLETE"
echo "============================================"
echo ""
echo "Tips:"
echo "  - Load/Seek commands: Check if state.position_ms is used (not frame.position)"
echo "  - Mid-song takeover: Player should start at position in Load command"
echo "  - Use getPositionFromFrame() helper for consistent position extraction"
