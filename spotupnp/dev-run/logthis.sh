#!/bin/bash

# Configuration
SPOTCONNECT_DIR="$HOME/.spotconnect"
LOG_FILE="$SPOTCONNECT_DIR/spotupnp.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGTHIS_FILE="$SCRIPT_DIR/logthis.log"
LOG_MARKER_FILE="/tmp/.logthis_line_marker"

# Function to show help
show_help() {
    echo "Usage: $0 {0|1|2}"
    echo ""
    echo "  0  - Mark current position in log file (set snapshot start point)"
    echo "  1  - Snapshot log from marked position and copy to clipboard"
    echo "  2  - Analyze snapshot and show summary"
    echo ""
}

# Check argument
case "$1" in
    0)
        # Mark current line number in log file (for subsequent snapshots)
        if [[ -f "$LOG_FILE" ]]; then
            CURRENT_LINES=$(wc -l < "$LOG_FILE")
            echo "$CURRENT_LINES" > "$LOG_MARKER_FILE"
            echo "Marked position at line $CURRENT_LINES in log file"
            echo "Next snapshot (option 1) will capture logs from this point forward."
        else
            echo "0" > "$LOG_MARKER_FILE"
            echo "Log file not found, marker set to line 0"
        fi
        if [[ -f "$LOGTHIS_FILE" ]]; then
            rm "$LOGTHIS_FILE"
            echo "Previous snapshot removed."
        fi
        ;;
    1)
        # Copy log file from marker position to clipboard (strip ANSI color codes) and save to logthis.log
        if [[ -f "$LOG_FILE" ]]; then
            # Read marker (start from line 0 if no marker exists)
            START_LINE=0
            if [[ -f "$LOG_MARKER_FILE" ]]; then
                START_LINE=$(cat "$LOG_MARKER_FILE")
            fi
            
            TOTAL_LINES=$(wc -l < "$LOG_FILE")
            LINES_TO_CAPTURE=$((TOTAL_LINES - START_LINE))
            
            if [[ $LINES_TO_CAPTURE -gt 0 ]]; then
                tail -n "$LINES_TO_CAPTURE" "$LOG_FILE" | \
                    sed -r 's/\x1b\[[0-9;]*m//g; s/\x1b\[//g; s/^\[[0-9;]*m//g' | \
                    tee "$LOGTHIS_FILE" | xclip -selection clipboard
                echo "Captured $LINES_TO_CAPTURE lines (from line $START_LINE to $TOTAL_LINES)"
                echo "Snapshot saved to $LOGTHIS_FILE and copied to clipboard"
            else
                echo "No new log lines since marker at line $START_LINE (current: $TOTAL_LINES lines)"
                exit 1
            fi
        else
            echo "Error: Log file not found: $LOG_FILE"
            exit 1
        fi
        ;;
    2)
        # Analyze log file
        if [[ -x "$SCRIPT_DIR/logthis-analyze.sh" ]]; then
            if [[ -f "$LOGTHIS_FILE" ]]; then
                # Try to find config.xml in script directory
                CONFIG_FILE="$SCRIPT_DIR/config.xml"
                if [[ -f "$CONFIG_FILE" ]]; then
                    "$SCRIPT_DIR/logthis-analyze.sh" --file "$LOGTHIS_FILE" --config "$CONFIG_FILE"
                else
                    "$SCRIPT_DIR/logthis-analyze.sh" --file "$LOGTHIS_FILE"
                fi
            else
                echo "Error: No snapshot found. Run './logthis.sh 1' first to create a snapshot."
                exit 1
            fi
        else
            echo "Error: logthis-analyze.sh not found or not executable"
            exit 1
        fi
        ;;
    *)
        # Show help for no argument or unexpected argument
        show_help
        exit 1
        ;;
esac
