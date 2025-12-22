#!/bin/bash

# Configuration
SPOTCONNECT_DIR="$HOME/.spotconnect"
LOG_FILE="$SPOTCONNECT_DIR/spotupnp.log"

# Function to show help
show_help() {
    echo "Usage: $0 {0|1}"
    echo ""
    echo "  0  - Reset (clear) the log file"
    echo "  1  - Copy log file to clipboard (ANSI codes stripped)"
    echo ""
    echo "Log file: $LOG_FILE"
}

# Check argument
case "$1" in
    0)
        # Reset log file
        echo "Clearing log file: $LOG_FILE"
        > "$LOG_FILE"
        echo "Log file cleared."
        ;;
    1)
        # Copy log file to clipboard (strip ANSI color codes)
        if [[ -f "$LOG_FILE" ]]; then
            sed -r 's/\x1b\[[0-9;]*m//g; s/\x1b\[//g; s/^\[[0-9;]*m//g' "$LOG_FILE" | xclip -selection clipboard
            echo "Log file copied to clipboard ($(wc -l < "$LOG_FILE") lines)"
        else
            echo "Error: Log file not found: $LOG_FILE"
            exit 1
        fi
        ;;
    *)
        # Show help for no argument or unexpected argument
        show_help
        exit 1
        ;;
esac
