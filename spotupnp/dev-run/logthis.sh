#!/bin/bash

# Configuration
SPOTCONNECT_DIR="$HOME/.spotconnect"
LOG_FILE="$SPOTCONNECT_DIR/spotupnp.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGTHIS_FILE="$SCRIPT_DIR/logthis.log"

# Function to show help
show_help() {
    echo "Usage: $0 {0|1|2}"
    echo ""
    echo "  0  - Reset (clear) the log file"
    echo "  1  - Snapshot current log file and copy to clipboard"
    echo "  2  - Analyze log file and show summary"
    echo ""
}

# Check argument
case "$1" in
    0)
        # Reset log file and remove logthis.log
        echo "Clearing log file: $LOG_FILE"
        > "$LOG_FILE"
        if [[ -f "$LOGTHIS_FILE" ]]; then
            rm "$LOGTHIS_FILE"
            echo "Log file cleared and logthis.log removed."
        else
            echo "Log file cleared."
        fi
        ;;
    1)
        # Copy log file to clipboard (strip ANSI color codes) and save to logthis.log
        if [[ -f "$LOG_FILE" ]]; then
            sed -r 's/\x1b\[[0-9;]*m//g; s/\x1b\[//g; s/^\[[0-9;]*m//g' "$LOG_FILE" | tee "$LOGTHIS_FILE" | xclip -selection clipboard
            echo "Log file copied to clipboard and saved to $LOGTHIS_FILE ($(wc -l < "$LOG_FILE") lines)"
        else
            echo "Error: Log file not found: $LOG_FILE"
            exit 1
        fi
        ;;
    2)
        # Analyze log file
        if [[ -x "$SCRIPT_DIR/analyze-log.sh" ]]; then
            if [[ -f "$LOGTHIS_FILE" ]]; then
                # Try to find config.xml in script directory
                CONFIG_FILE="$SCRIPT_DIR/config.xml"
                if [[ -f "$CONFIG_FILE" ]]; then
                    "$SCRIPT_DIR/analyze-log.sh" --file "$LOGTHIS_FILE" --config "$CONFIG_FILE"
                else
                    "$SCRIPT_DIR/analyze-log.sh" --file "$LOGTHIS_FILE"
                fi
            else
                echo "Error: No snapshot found. Run './logthis.sh 1' first to create a snapshot."
                exit 1
            fi
        else
            echo "Error: analyze-log.sh not found or not executable"
            exit 1
        fi
        ;;
    *)
        # Show help for no argument or unexpected argument
        show_help
        exit 1
        ;;
esac
