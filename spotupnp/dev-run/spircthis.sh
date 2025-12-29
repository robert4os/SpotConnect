#!/bin/bash

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPIRCTHIS_FILE="$SCRIPT_DIR/spircthis.txt"

# Function to show help
show_help() {
    echo "Usage: $0 --deviceid <deviceid> {0|1|2}"
    echo ""
    echo "Required:"
    echo "  --deviceid <deviceid>  Device ID for SPIRC file identification"
    echo ""
    echo "Commands:"
    echo "  0  - Reset (clear/truncate) the SPIRC file"
    echo "  1  - Snapshot current SPIRC file and copy to clipboard"
    echo "  2  - Analyze SPIRC file and show summary"
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

# Execute command
case "$COMMAND" in
    0)
        # Reset/truncate SPIRC file and remove spircthis.txt
        if [[ -f "$SPIRC_FILE" ]]; then
            echo "Truncating SPIRC file: $SPIRC_FILE"
            > "$SPIRC_FILE"
        else
            echo "SPIRC file does not exist: $SPIRC_FILE"
        fi
        
        if [[ -f "$SPIRCTHIS_FILE" ]]; then
            rm "$SPIRCTHIS_FILE"
            echo "SPIRC file truncated and spircthis.txt removed."
        else
            echo "SPIRC file truncated."
        fi
        ;;
    1)
        # Copy SPIRC file to clipboard (strip ANSI color codes) and save to spircthis.txt
        if [[ -f "$SPIRC_FILE" ]]; then
            sed -r 's/\x1b\[[0-9;]*m//g; s/\x1b\[//g; s/^\[[0-9;]*m//g' "$SPIRC_FILE" | tee "$SPIRCTHIS_FILE" | xclip -selection clipboard
            echo "SPIRC file copied to clipboard and saved to $SPIRCTHIS_FILE ($(wc -l < "$SPIRC_FILE") lines)"
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
