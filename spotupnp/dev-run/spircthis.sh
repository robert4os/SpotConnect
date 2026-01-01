#!/bin/bash

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPIRCTHIS_FILE="$SCRIPT_DIR/spircthis.log"

# Function to show help
show_help() {
    echo "Usage: $0 --deviceid <deviceid> {0|1|2}"
    echo ""
    echo "Required:"
    echo "  --deviceid <deviceid>  Device ID for SPIRC file identification"
    echo ""
    echo "Commands:"
    echo "  0  - Mark current position in SPIRC file (set snapshot start point)"
    echo "  1  - Snapshot SPIRC from marked position and copy to clipboard"
    echo "  2  - Analyze snapshot and show summary"
    echo ""
    echo "Example:"
    echo "  $0 --deviceid dc419c953f5e3538855ab5271478674248463917177 1"
    echo ""
}

# Parse arguments
DEVICEID=""
COMMAND=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deviceid)
            DEVICEID="$2"
            shift 2
            ;;
        0|1|2)
            COMMAND="$1"
            shift
            ;;
        *)
            echo "Error: Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "$DEVICEID" ]]; then
    echo "Error: --deviceid is required"
    echo ""
    show_help
    exit 1
fi

if [[ -z "$COMMAND" ]]; then
    echo "Error: Command (0, 1, or 2) is required"
    echo ""
    show_help
    exit 1
fi

# Build SPIRC file path
SPIRC_FILE="/tmp/spotupnp-device-spirc-${DEVICEID}.log"
SPIRC_MARKER_FILE="/tmp/.spircthis_line_marker_${DEVICEID}"

# Execute command
case "$COMMAND" in
    0)
        # Mark current line number in SPIRC file (for subsequent snapshots)
        if [[ -f "$SPIRC_FILE" ]]; then
            CURRENT_LINES=$(wc -l < "$SPIRC_FILE")
            echo "$CURRENT_LINES" > "$SPIRC_MARKER_FILE"
            echo "Marked position at line $CURRENT_LINES in SPIRC file"
            echo "Next snapshot (option 1) will capture SPIRC frames from this point forward."
        else
            echo "0" > "$SPIRC_MARKER_FILE"
            echo "SPIRC file not found, marker set to line 0"
        fi
        if [[ -f "$SPIRCTHIS_FILE" ]]; then
            rm "$SPIRCTHIS_FILE"
            echo "Previous snapshot removed."
        fi
        ;;
    1)
        # Copy SPIRC file from marker position to clipboard (strip ANSI color codes) and save to spircthis.log
        if [[ -f "$SPIRC_FILE" ]]; then
            # Read marker (start from line 0 if no marker exists)
            START_LINE=0
            if [[ -f "$SPIRC_MARKER_FILE" ]]; then
                START_LINE=$(cat "$SPIRC_MARKER_FILE")
            fi
            
            TOTAL_LINES=$(wc -l < "$SPIRC_FILE")
            LINES_TO_CAPTURE=$((TOTAL_LINES - START_LINE))
            
            if [[ $LINES_TO_CAPTURE -gt 0 ]]; then
                tail -n "$LINES_TO_CAPTURE" "$SPIRC_FILE" | \
                    sed -r 's/\x1b\[[0-9;]*m//g; s/\x1b\[//g; s/^\[[0-9;]*m//g' | \
                    tee "$SPIRCTHIS_FILE" | xclip -selection clipboard
                echo "Captured $LINES_TO_CAPTURE lines (from line $START_LINE to $TOTAL_LINES)"
                echo "Snapshot saved to $SPIRCTHIS_FILE and copied to clipboard"
            else
                echo "No new SPIRC frames since marker at line $START_LINE (current: $TOTAL_LINES lines)"
                exit 1
            fi
        else
            echo "Error: SPIRC file not found: $SPIRC_FILE"
            exit 1
        fi
        ;;
    2)
        # Analyze SPIRC file
        if [[ -x "$SCRIPT_DIR/spircthis-analyze.sh" ]]; then
            if [[ -f "$SPIRCTHIS_FILE" ]]; then
                "$SCRIPT_DIR/spircthis-analyze.sh" --file "$SPIRCTHIS_FILE"
            else
                echo "Error: No snapshot found. Run '$0 --deviceid $DEVICEID 1' first to create a snapshot."
                exit 1
            fi
        else
            echo "Error: spircthis-analyze.sh not found or not executable"
            exit 1
        fi
        ;;
esac
