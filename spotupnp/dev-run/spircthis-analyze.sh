#!/bin/bash

# spircthis-analyze.sh - SPIRC Protocol Analysis Tool
# Analyzes SPIRC debug files to understand message flow and identify issues

SPIRC_FILE="${1:-/tmp/spotupnp-device-spirc-dc419c953f5e3538855ab5271478674248463917177.txt}"

if [ ! -f "$SPIRC_FILE" ]; then
    echo "Error: SPIRC debug file not found: $SPIRC_FILE"
    echo "Usage: $0 [spirc-debug-file]"
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
    if (msg_type == "Load") {
        print "  Load: frame.position=" frame_pos " ms, state.position_ms=" state_pos " ms"
        if (frame_pos == "0" && state_pos != "0") {
            print "    ✓ Load uses state.position_ms as TARGET (frame.position always 0)"
        } else if (frame_pos != "0") {
            print "    ⚠ Unexpected: frame.position=" frame_pos " (should be 0 for Load)"
        }
    } else if (msg_type == "Seek") {
        print "  Seek: frame.position=" frame_pos " ms, state.position_ms=" state_pos " ms"
        if (frame_pos != state_pos) {
            print "    ✓ Seek uses frame.position=" frame_pos " as TARGET (state.position_ms=" state_pos " is CURRENT)"
        } else {
            print "    ⚠ Warning: Both fields same value, unclear which is target"
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

# Track progression analysis
echo "=== TRACK PROGRESSION ANALYSIS ==="
awk '
BEGIN {
    prev_track_index = -1
    track_count = 0
    incoming = 0
    outgoing = 0
}

/^=== INCOMING FRAME ===/ {
    incoming = 1
    outgoing = 0
    next
}

/^=== OUTGOING FRAME ===/ {
    incoming = 0
    outgoing = 1
    next
}

incoming && /^--- Track Queue \(([0-9]+) tracks\)/ {
    match($0, /\(([0-9]+) tracks\)/, arr)
    track_count = arr[1]
    print "  Incoming Load/Replace with " track_count " tracks in queue"
    next
}

incoming && /^\[([0-9]+)\] Track ID: ([a-f0-9]+)/ {
    match($0, /\[([0-9]+)\] Track ID: ([a-f0-9]+)/, arr)
    idx = arr[1]
    track_id = arr[2]
    marker = ($0 ~ /← CURRENT/) ? " ← CURRENT" : ""
    if (marker != "") {
        print "    Starting at track [" idx "]: " track_id
    }
    next
}

outgoing && /^Playing Track Index: ([0-9]+)/ {
    match($0, /Playing Track Index: ([0-9]+)/, arr)
    track_index = arr[1]
    
    if (prev_track_index >= 0 && track_index != prev_track_index) {
        print "  ✓ Track transition: [" prev_track_index "] → [" track_index "] (player-driven, no incoming command)"
    } else if (prev_track_index < 0) {
        print "  Playing track index: [" track_index "]"
    }
    
    prev_track_index = track_index
    next
}

END {
    if (track_count > 0 && prev_track_index >= 0) {
        if (prev_track_index == track_count - 1) {
            print "  ℹ Playback ended on last track [" prev_track_index "] of " track_count " tracks"
        } else {
            print "  ℹ Session ended at track [" prev_track_index "] of " track_count " tracks"
        }
    } else if (prev_track_index < 0) {
        print "  ℹ No track progression detected (outgoing frames may not include track index)"
    }
    
    if (track_count > 1 && prev_track_index >= 0) {
        print ""
        print "  ℹ Note: Track transitions are player-driven (automatic queue progression)."
        print "         Spotify only sends Load frame initially; player advances through queue."
    }
}
' "$SPIRC_FILE"

echo ""

# Repeat/Shuffle State Tracking
echo "=== REPEAT/SHUFFLE STATE TRACKING ==="
awk '
BEGIN {
    repeat_state = "unknown"
    shuffle_state = "unknown"
    incoming = 0
    seen_repeat = 0
    seen_shuffle = 0
}

/^=== INCOMING FRAME ===/ {
    incoming = 1
    next
}

/^=== OUTGOING FRAME ===/ {
    incoming = 0
    next
}

incoming && /^Message Type: Repeat/ {
    print "  Received Repeat command from Spotify"
    next
}

incoming && /^Message Type: Shuffle/ {
    print "  Received Shuffle command from Spotify"
    next
}

incoming && /^Repeat: true/ {
    if (repeat_state == "false") {
        print "  ✓ Repeat state transition: OFF → ON"
    } else if (!seen_repeat) {
        print "  Repeat mode: ON (initial state)"
    }
    repeat_state = "true"
    seen_repeat = 1
    next
}

incoming && /^Repeat: false/ {
    if (repeat_state == "true") {
        print "  ✓ Repeat state transition: ON → OFF"
    } else if (!seen_repeat) {
        print "  Repeat mode: OFF (initial state)"
    }
    repeat_state = "false"
    seen_repeat = 1
    next
}

incoming && /^Shuffle: true/ {
    if (shuffle_state == "false") {
        print "  ✓ Shuffle state transition: OFF → ON"
    } else if (!seen_shuffle) {
        print "  Shuffle mode: ON (initial state)"
    }
    shuffle_state = "true"
    seen_shuffle = 1
    next
}

incoming && /^Shuffle: false/ {
    if (shuffle_state == "true") {
        print "  ✓ Shuffle state transition: ON → OFF"
    } else if (!seen_shuffle) {
        print "  Shuffle mode: OFF (initial state)"
    }
    shuffle_state = "false"
    seen_shuffle = 1
    next
}

END {
    if (seen_repeat || seen_shuffle) {
        print ""
        print "  Final state:"
        if (seen_repeat) {
            print "    Repeat: " (repeat_state == "true" ? "ON" : "OFF")
        }
        if (seen_shuffle) {
            print "    Shuffle: " (shuffle_state == "true" ? "ON" : "OFF")
        }
    } else {
        print "  ℹ No repeat or shuffle state changes detected"
    }
}
' "$SPIRC_FILE"

echo ""

# Detect repeat loops
echo "=== LOOP DETECTION ==="
awk '
BEGIN {
    prev_out_pos = -1
    repeat_enabled = 0
    current_track = ""
    prev_track = ""
    incoming = 0
    outgoing = 0
    loop_count = 0
}

/^=== INCOMING FRAME ===/ {
    incoming = 1
    outgoing = 0
    next
}

/^=== OUTGOING FRAME ===/ {
    incoming = 0
    outgoing = 1
    next
}

incoming && /^Repeat: true/ {
    repeat_enabled = 1
    next
}

incoming && /^Repeat: false/ {
    repeat_enabled = 0
    next
}

/^\[0\] Track ID: / {
    current_track = $4
    gsub(" ←.*", "", current_track)
    next
}

outgoing && /^Position:/ && !/Top-level/ && !/Measured/ {
    pos = $2
    gsub(" ms", "", pos)
    
    if (prev_out_pos > 10000 && pos == 0 && repeat_enabled) {
        loop_count++
        if (current_track != "" && current_track == prev_track) {
            print "  ✓ Track loop detected: position reset to 0 (repeat mode enabled)"
            print "    Same track restarted: " current_track
            print "    Previous position: " prev_out_pos " ms (" prev_out_pos/1000 " seconds)"
        } else if (current_track != "" && current_track != prev_track) {
            print "  ℹ Track transition: position reset to 0"
            print "    Previous track: " prev_track " → New track: " current_track
        } else {
            print "  ✓ Loop detected: position reset to 0 (repeat mode enabled)"
            print "    Previous position: " prev_out_pos " ms (" prev_out_pos/1000 " seconds)"
        }
    }
    
    prev_out_pos = pos
    if (current_track != "") {
        prev_track = current_track
    }
}

END {
    if (loop_count == 0) {
        print "  ℹ No track loops detected in this session"
    }
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

# Check for unexpected position changes (excluding Seek commands and repeat loops)
echo ""
awk '
BEGIN {
    prev_out_pos = -1
    rapid_changes = 0
    seek_pending = 0
    repeat_enabled = 0
}

/^=== INCOMING FRAME ===/ {
    incoming = 1
    outgoing = 0
    next
}

/^=== OUTGOING FRAME ===/ {
    incoming = 0
    outgoing = 1
    next
}

incoming && /^Message Type: Seek/ {
    seek_pending = 1
    next
}

incoming && /^Repeat: true/ {
    repeat_enabled = 1
    next
}

incoming && /^Repeat: false/ {
    repeat_enabled = 0
    next
}

outgoing && /^Position:/ && !/Top-level/ && !/Measured/ {
    pos = $2
    gsub(" ms", "", pos)
    
    if (prev_out_pos >= 0 && !seek_pending) {
        diff = pos - prev_out_pos
        # Check for unexpected jumps, but ignore loop restarts (large backward jump to 0 with repeat enabled)
        is_loop_restart = (prev_out_pos > 10000 && pos == 0 && repeat_enabled)
        
        if (diff < -1000 && !is_loop_restart) {
            rapid_changes++
            print "  ⚠ Unexpected position jump backward: " prev_out_pos " ms → " pos " ms (Δ " diff " ms)"
        } else if (diff > 30000) {
            rapid_changes++
            print "  ⚠ Unexpected position jump forward: " prev_out_pos " ms → " pos " ms (Δ " diff " ms)"
        }
    }
    
    # Clear seek flag after first outgoing position update
    if (seek_pending) {
        seek_pending = 0
    }
    
    prev_out_pos = pos
}

END {
    if (rapid_changes == 0) {
        print "  ✓ No unexpected position jumps detected"
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
echo "  - Load: Uses state.position_ms as TARGET position (frame.position always 0)"
echo "  - Seek: Uses frame.position as TARGET position (state.position_ms is CURRENT)"
echo "  - These opposite semantics are a Spotify protocol quirk!"
