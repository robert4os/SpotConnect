#!/bin/bash
# Analyzes spotupnp logs and extracts key metrics

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Required arguments
LOG_FILE=""
CONFIG_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --file)
            LOG_FILE="$2"
            shift 2
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown argument: $1"
            echo ""
            echo "Usage: $0 --file <log> [--config <config.xml>]"
            echo ""
            echo "Required:"
            echo "  --file <log>     Path to log file to analyze"
            echo ""
            echo "Optional:"
            echo "  --config <xml>   Path to config.xml file"
            exit 1
            ;;
    esac
done

# Validate required argument
if [[ -z "$LOG_FILE" ]]; then
    echo "Error: --file is required"
    echo ""
    echo "Usage: $0 --file <log> [--config <config.xml>]"
    exit 1
fi

if [[ ! -f "$LOG_FILE" ]]; then
    echo "Error: Log file not found: $LOG_FILE"
    exit 1
fi

# Try to detect config file from log if not specified
if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FROM_LOG=$(grep "Config:" "$LOG_FILE" | head -1 | grep -oP 'Config:\s+\K[^ ]+')
    if [[ -n "$CONFIG_FROM_LOG" && -f "$CONFIG_FROM_LOG" ]]; then
        CONFIG_FILE="$CONFIG_FROM_LOG"
    fi
fi

# Parse config if available
declare -A CONFIG
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    CONFIG[flow]=$(grep -oP '<flow>\K[^<]+' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
    CONFIG[gapless]=$(grep -oP '<gapless>\K[^<]+' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
    CONFIG[codec]=$(grep -oP '<codec>\K[^<]+' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
    CONFIG[vorbis_rate]=$(grep -oP '<vorbis_rate>\K[^<]+' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
    CONFIG[send_metadata]=$(grep -oP '<send_metadata>\K[^<]+' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
    CONFIG[use_filecache]=$(grep -oP '<use_filecache>\K[^<]+' "$CONFIG_FILE" 2>/dev/null || echo "unknown")
fi

echo "============================================"
echo "  SPOTUPNP LOG ANALYSIS"
echo "============================================"
echo "Log: $LOG_FILE"
echo "Size: $(wc -l < "$LOG_FILE") lines"
if [[ -n "$CONFIG_FILE" ]]; then
    echo "Config: $CONFIG_FILE"
fi
echo ""

# Show config values early if available
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    echo "=== CONFIGURATION ==="
    echo "  flow: ${CONFIG[flow]}"
    echo "  gapless: ${CONFIG[gapless]}"
    echo "  codec: ${CONFIG[codec]}"
    echo "  vorbis_rate: ${CONFIG[vorbis_rate]}"
    echo "  send_metadata: ${CONFIG[send_metadata]}"
    echo "  use_filecache: ${CONFIG[use_filecache]}"
    echo ""
fi

# Session info
echo "=== SESSION INFO ==="
SESSION_START=$(grep "SPOTCONNECT START" "$LOG_FILE" | tail -1)
if [[ -n "$SESSION_START" ]]; then
    echo "$SESSION_START" | grep -oP 'SPOTCONNECT START - \K.*'
else
    echo "No session start marker found"
fi
echo ""

# Track playback summary
echo "=== TRACK PLAYBACK ==="
TRACK_COUNT=$(grep -c "new track id.*=>" "$LOG_FILE")
echo "Tracks played: $TRACK_COUNT"
if [[ $TRACK_COUNT -gt 0 ]]; then
    echo ""
    echo "Track list:"
    grep "new track id.*=>" "$LOG_FILE" | sed 's/.*=> </  - </g' | nl -w2 -s'. '
fi
echo ""

# Flow mode detection
echo "=== FLOW MODE STATUS ==="
FLOW_MARKERS=$(grep -c "\[FLOW\] Set marker" "$LOG_FILE")
FLOW_BOUNDARIES=$(grep -c "\[FLOW\] Track boundary" "$LOG_FILE")
FLOW_SUBSEQUENT=$(grep -c "\[FLOW\] Track .* will start at" "$LOG_FILE")
HTTP_PORTS=$(grep -c "Bound to port" "$LOG_FILE")
FLOW_ACTIVE=$(grep -c "\[ANALYSIS:FLOW_ACTIVE\]" "$LOG_FILE")
DISCRETE_MODE=$(grep -c "\[ANALYSIS:DISCRETE_MODE\]" "$LOG_FILE")

if [[ $FLOW_ACTIVE -gt 0 ]]; then
    echo -e "${GREEN}✓${NC} Flow mode: ACTIVE (continuous streaming)"
    echo "  - Flow markers: $FLOW_MARKERS"
    echo "  - Track boundaries crossed: $FLOW_BOUNDARIES"
    echo "  - Subsequent tracks in flow: $FLOW_SUBSEQUENT"
elif [[ $DISCRETE_MODE -gt 0 ]]; then
    echo -e "${RED}✗${NC} Flow mode: INACTIVE (discrete track mode)"
    echo "  - Discrete track loads: $DISCRETE_MODE"
elif [[ $FLOW_MARKERS -gt 0 && $FLOW_SUBSEQUENT -gt 0 ]]; then
    echo -e "${GREEN}✓${NC} Flow mode: ACTIVE (continuous streaming)"
    echo "  - Flow markers: $FLOW_MARKERS"
    echo "  - Subsequent tracks in flow: $FLOW_SUBSEQUENT"
    echo "  - Track boundaries crossed: $FLOW_BOUNDARIES"
else
    echo -e "${RED}✗${NC} Flow mode: INACTIVE (discrete track mode)"
    echo "  - Flow markers created: $FLOW_MARKERS (but not used)"
fi

echo "  - HTTP connections opened: $HTTP_PORTS"
if [[ $HTTP_PORTS -gt 1 ]]; then
    echo -e "  ${YELLOW}⚠${NC} Multiple HTTP streams = discrete track mode"
    grep "Bound to port" "$LOG_FILE" | sed 's/.* port /    Port /g' | nl -w2 -s'. '
fi
echo ""

# Rate limiting analysis
echo "=== RATE LIMITING ==="
TRACK_NUM=0
declare -a EXPECTED_TIMES
declare -a SLEPT_TIMES

while IFS= read -r line; do
    EXPECTED=$(echo "$line" | grep -oP 'expected time: \K[0-9.]+')
    EXPECTED_TIMES+=("$EXPECTED")
done < <(grep "EOF - expected time:" "$LOG_FILE")

while IFS= read -r line; do
    SLEPT=$(echo "$line" | grep -oP 'Total sleep time: \K[0-9.]+')
    SLEPT_TIMES+=("$SLEPT")
done < <(grep "\[RATE-LIMIT\] Total sleep time:" "$LOG_FILE")

if [[ ${#EXPECTED_TIMES[@]} -gt 0 ]]; then
    for i in "${!EXPECTED_TIMES[@]}"; do
        TRACK_NUM=$((i + 1))
        EXPECTED=${EXPECTED_TIMES[$i]}
        SLEPT=${SLEPT_TIMES[$i]:-"N/A"}
        
        if [[ "$SLEPT" != "N/A" ]]; then
            DIFF=$(awk "BEGIN {printf \"%.1f\", $EXPECTED - $SLEPT}")
            PCT=$(awk "BEGIN {printf \"%.1f\", ($SLEPT / $EXPECTED) * 100}")
            echo "Track $TRACK_NUM: duration=${EXPECTED}s, slept=${SLEPT}s (${PCT}%), overhead=${DIFF}s"
        else
            echo "Track $TRACK_NUM: duration=${EXPECTED}s, slept=N/A"
        fi
    done
    
    # Check for analysis markers
    COMPLETE_MARKERS=$(grep -c "\[ANALYSIS:TRACK_COMPLETE\]" "$LOG_FILE")
    if [[ $COMPLETE_MARKERS -gt 0 ]]; then
        echo ""
        echo "Detailed track completion data:"
        grep "\[ANALYSIS:TRACK_COMPLETE\]" "$LOG_FILE" | sed 's/.*\[ANALYSIS:TRACK_COMPLETE\] /  /g'
    fi
else
    echo "No completed tracks found"
fi
echo ""

# Repeat mode status
echo "=== REPEAT MODE ==="
if grep -q "\[REPEAT\] isFinished=false" "$LOG_FILE"; then
    echo "Repeat: ENABLED"
    LOOPS=$(grep -c "\[EOF\] Repeat enabled, skipping to next" "$LOG_FILE")
    echo "  Loop iterations: $LOOPS"
    
    # Show loop details if any
    if [[ $LOOPS -gt 0 ]]; then
        echo "  Loop events:"
        grep "\[EOF\] Repeat enabled, skipping to next\|\[FLOW\] Playlist loop detected" "$LOG_FILE" | \
            sed 's/.*\] /    /g' | nl -w2 -s'. '
    fi
else
    echo "Repeat: DISABLED"
fi
echo ""

# Premature EOF detection after seeks
echo "=== SEEK TIMING ANALYSIS ==="
SEEK_EVENTS=$(grep -n "\[SEEK\] Seeking from" "$LOG_FILE")
if [[ -n "$SEEK_EVENTS" ]]; then
    PREMATURE_EOF_FOUND=0
    
    echo "$SEEK_EVENTS" | while IFS=: read -r SEEK_LINE SEEK_CONTENT; do
        # Extract seek target position (in ms) - format: "[SEEK] Seeking from X ms to Y ms"
        SEEK_POS=$(echo "$SEEK_CONTENT" | grep -oP 'to \K[0-9]+(?= ms \(target)')
        
        # Extract timestamp
        SEEK_TIME=$(echo "$SEEK_CONTENT" | grep -oP '^\[[0-9:\.]+\]')
        
        # Find track duration from nearby metadata
        START_LINE=$((SEEK_LINE > 20 ? SEEK_LINE - 20 : 1))
        TRACK_DURATION=$(sed -n "${START_LINE},$((SEEK_LINE + 5))p" "$LOG_FILE" | grep -E "duration_ms=|Track duration:" | tail -1 | grep -oP '(duration_ms=|Track duration: )\K[0-9]+')
        
        if [[ -z "$TRACK_DURATION" ]]; then
            # Try to find duration from the session start or nearby logs
            TRACK_DURATION=$(grep -E "duration_ms=|Track duration:" "$LOG_FILE" | grep -B5 "$SEEK_TIME" | tail -1 | grep -oP '(duration_ms=|Track duration: )\K[0-9]+')
        fi
        
        # Find EOF after seek
        EOF_LINE=$(tail -n +$SEEK_LINE "$LOG_FILE" | grep -n "EOF - expected time:" | head -1 | cut -d: -f1)
        
        if [[ -n "$EOF_LINE" && -n "$SEEK_POS" && -n "$TRACK_DURATION" ]]; then
            ACTUAL_EOF_LINE=$((SEEK_LINE + EOF_LINE - 1))
            EOF_TIME=$(sed -n "${ACTUAL_EOF_LINE}p" "$LOG_FILE" | grep -oP '^\[[0-9:\.]+\]')
            
            # Calculate expected remaining playback
            REMAINING_MS=$((TRACK_DURATION - SEEK_POS))
            REMAINING_SEC=$(awk "BEGIN {printf \"%.1f\", $REMAINING_MS / 1000.0}")
            
            # Extract actual playback time from seek to EOF
            if [[ -n "$SEEK_TIME" && -n "$EOF_TIME" ]]; then
                SEEK_SEC=$(echo "$SEEK_TIME" | sed 's/\[//; s/\]//; s/:/ /g' | awk '{print ($1 * 3600) + ($2 * 60) + $3}')
                EOF_SEC=$(echo "$EOF_TIME" | sed 's/\[//; s/\]//; s/:/ /g' | awk '{print ($1 * 3600) + ($2 * 60) + $3}')
                ACTUAL_PLAYBACK=$(awk "BEGIN {printf \"%.1f\", $EOF_SEC - $SEEK_SEC}")
                
                # Calculate difference
                DIFF=$(awk "BEGIN {printf \"%.1f\", $REMAINING_SEC - $ACTUAL_PLAYBACK}")
                
                # Flag if significantly premature (>5 seconds early)
                IS_PREMATURE=$(awk "BEGIN {print ($DIFF > 5.0)}")
                
                if [[ $IS_PREMATURE -eq 1 ]]; then
                    echo -e "${RED}✗ PREMATURE EOF DETECTED${NC}"
                    echo "  Seek position: ${SEEK_POS}ms ($(awk "BEGIN {printf \"%.1f\", $SEEK_POS / 1000.0}")s)"
                    echo "  Track duration: ${TRACK_DURATION}ms ($(awk "BEGIN {printf \"%.1f\", $TRACK_DURATION / 1000.0}")s)"
                    echo "  Expected remaining: ${REMAINING_SEC}s"
                    echo "  Actual playback: ${ACTUAL_PLAYBACK}s"
                    echo -e "  ${RED}Ended ${DIFF}s too early${NC}"
                    echo ""
                    echo "  Root cause: TrackPlayer decoder doesn't reset state after seek"
                    echo "  Impact: Decoder counts full track duration instead of remaining portion"
                    PREMATURE_EOF_FOUND=1
                else
                    echo -e "${GREEN}✓${NC} Seek timing OK"
                    echo "  Seek position: ${SEEK_POS}ms, remaining: ${REMAINING_SEC}s"
                    echo "  Actual playback: ${ACTUAL_PLAYBACK}s (difference: ${DIFF}s)"
                fi
            fi
        else
            echo "Seek detected but insufficient timing data for analysis"
            [[ -n "$SEEK_POS" ]] && echo "  Seek position: ${SEEK_POS}ms"
        fi
    done
else
    echo "No seek operations detected"
fi
echo ""

# Authentication and token analysis
echo "=== AUTHENTICATION & TOKENS ==="
NUM_CLIENTS=$(grep -c "Spotify client launched for" "$LOG_FILE")
TOKEN_FETCHES=$(grep -c "Access token expired, fetching new one" "$LOG_FILE")
TOKEN_SUCCESS=$(grep -c "Access token fetched successfully" "$LOG_FILE")
TOKEN_FAILURES=$(grep -c "Access token fetch failed:" "$LOG_FILE")
AUTH_429=$(grep -c "Access token fetch failed: HTTP 429" "$LOG_FILE")

echo "Spotify clients launched: $NUM_CLIENTS"
if [[ $NUM_CLIENTS -gt 0 ]]; then
    grep "Spotify client launched for" "$LOG_FILE" | sed 's/.*launched for /  - /g'
fi

# Authentication method analysis
USERPASS_AUTH=$(grep -c "Using USER_PASS authentication" "$LOG_FILE")
STORED_AUTH=$(grep -c "Using STORED credentials" "$LOG_FILE")
ZEROCONF_AUTH=$(grep -c "Using ZEROCONF authentication" "$LOG_FILE")

if [[ $((USERPASS_AUTH + STORED_AUTH + ZEROCONF_AUTH)) -gt 0 ]]; then
    echo ""
    echo "Authentication methods used:"
    [[ $USERPASS_AUTH -gt 0 ]] && echo "  USER_PASS (type 0): $USERPASS_AUTH times"
    [[ $STORED_AUTH -gt 0 ]] && echo "  STORED credentials (type 1+): $STORED_AUTH times"
    [[ $ZEROCONF_AUTH -gt 0 ]] && echo "  ZEROCONF: $ZEROCONF_AUTH times"
fi

# Show canonical usernames and credential types
CANONICAL_USERS=$(grep "Authorization successful for user:" "$LOG_FILE" | tail -5)
if [[ -n "$CANONICAL_USERS" ]]; then
    echo ""
    echo "Recent successful authentications:"
    grep "Authorization successful for user:" "$LOG_FILE" | tail -5 | while read line; do
        echo "  $line" | sed 's/.*for user: /User: /g'
        # Get the next 2 lines for account/credential types
        LINE_NUM=$(grep -n "Authorization successful for user:" "$LOG_FILE" | tail -5 | head -1 | cut -d: -f1)
        if [[ -n "$LINE_NUM" ]]; then
            sed -n "$((LINE_NUM+1)),$((LINE_NUM+2))p" "$LOG_FILE" | sed 's/^/    /g'
        fi
    done
fi

echo ""
echo "Access token activity:"
echo "  Token fetch attempts: $TOKEN_FETCHES"
echo "  Successful fetches: $TOKEN_SUCCESS"

if [[ $TOKEN_FAILURES -gt 0 ]]; then
    echo -e "  ${RED}✗${NC} Failed fetches: $TOKEN_FAILURES"
    if [[ $AUTH_429 -gt 0 ]]; then
        echo -e "    ${YELLOW}⚠${NC} Rate limited on auth endpoint: $AUTH_429"
    fi
fi

# Show token expiration times
TOKEN_EXPIRY=$(grep "expires in.*seconds" "$LOG_FILE" | tail -3)
if [[ -n "$TOKEN_EXPIRY" ]]; then
    echo ""
    echo "Recent token expiration times:"
    echo "$TOKEN_EXPIRY" | sed 's/.*expires in /  /g'
fi

# Warn about concurrent clients
if [[ $NUM_CLIENTS -gt 3 ]]; then
    echo ""
    echo -e "${YELLOW}⚠ Warning:${NC} Multiple concurrent clients ($NUM_CLIENTS) from same IP may trigger rate limiting"
    echo "  Consider staggering startup or reducing number of active clients"
fi
echo ""

# Error summary
echo "=== ERRORS & WARNINGS ==="
ERROR_COUNT=$(grep -c " E \|ERROR" "$LOG_FILE")
WARN_COUNT=$(grep -c " W \|WARNING" "$LOG_FILE")
echo "Errors: $ERROR_COUNT"
echo "Warnings: $WARN_COUNT"

if [[ $ERROR_COUNT -gt 0 ]]; then
    echo ""
    echo "Recent errors:"
    grep " E \|ERROR" "$LOG_FILE" | tail -5 | sed 's/^/  /g'
fi

if [[ $WARN_COUNT -gt 0 && $WARN_COUNT -le 10 ]]; then
    echo ""
    echo "Warnings:"
    grep " W \|WARNING" "$LOG_FILE" | sed 's/^/  /g'
fi
echo ""

# Rate limiting and retry analysis
echo "=== RATE LIMITING & RETRIES ==="
CDN_429=$(grep -c "CDN URL fetch failed: HTTP 429" "$LOG_FILE")
CDN_401=$(grep -c "CDN URL fetch failed: HTTP 401" "$LOG_FILE")
CDN_403=$(grep -c "CDN URL fetch failed: HTTP 403" "$LOG_FILE")
CDN_FAILURES=$(grep -c "CDN URL fetch failed:" "$LOG_FILE")
RETRY_AFTER=$(grep "Retry-After:" "$LOG_FILE" | tail -5)
TRACK_FAILURES=$(grep -c "Track failed to load, skipping it" "$LOG_FILE")
GAVE_UP=$(grep -c "Giving up after .* failures" "$LOG_FILE")
RATE_LIMIT_WAITS=$(grep -c "Rate limiting: waiting .* seconds as requested" "$LOG_FILE")
BACKOFF_WAITS=$(grep -c "Rate limiting: exponential backoff" "$LOG_FILE")
WAIT_COMPLETE=$(grep -c "Rate limiting: wait complete, resuming" "$LOG_FILE")

if [[ $CDN_FAILURES -gt 0 || $TRACK_FAILURES -gt 0 || $GAVE_UP -gt 0 ]]; then
    echo "CDN failures:"
    if [[ $CDN_429 -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠${NC} HTTP 429 (rate limiting): $CDN_429"
    fi
    if [[ $CDN_401 -gt 0 ]]; then
        echo -e "  ${RED}✗${NC} HTTP 401 (unauthorized): $CDN_401"
    fi
    if [[ $CDN_403 -gt 0 ]]; then
        echo -e "  ${RED}✗${NC} HTTP 403 (forbidden): $CDN_403"
    fi
    OTHER_FAILURES=$((CDN_FAILURES - CDN_429 - CDN_401 - CDN_403))
    if [[ $OTHER_FAILURES -gt 0 ]]; then
        echo "  Other CDN failures: $OTHER_FAILURES"
    fi
    
    if [[ -n "$RETRY_AFTER" ]]; then
        echo ""
        echo "Recent Retry-After headers:"
        echo "$RETRY_AFTER" | sed 's/.*Retry-After: /  Spotify requested: /g; s/ second.*/s delay/g'
    fi
    
    echo ""
    echo "Retry behavior:"
    echo "  Track load failures: $TRACK_FAILURES"
    echo "  Server-requested delays: $RATE_LIMIT_WAITS"
    echo "  Exponential backoff delays: $BACKOFF_WAITS"
    echo "  Completed delays: $WAIT_COMPLETE"
    
    if [[ $GAVE_UP -gt 0 ]]; then
        echo ""
        echo -e "  ${RED}✗${NC} Gave up retrying: $GAVE_UP times"
        grep "Giving up after" "$LOG_FILE" | sed 's/.*Giving up/  /g'
    fi
    
    # Show failure progression if available
    FAILURE_PROGRESS=$(grep "failure #[0-9]*/[0-9]*" "$LOG_FILE" | tail -10)
    if [[ -n "$FAILURE_PROGRESS" ]]; then
        echo ""
        echo "Recent failure progression:"
        echo "$FAILURE_PROGRESS" | sed 's/.*failure #/  Attempt /g; s/).*/) -/g' | sed 's/.*\] //'
    fi
else
    echo -e "${GREEN}✓${NC} No rate limiting or CDN failures detected"
fi
echo ""

# Connection errors analysis
echo "=== CONNECTION DIAGNOSTICS ==="
AP_CONNECT_ERRORS=$(grep -c "AP connect error" "$LOG_FILE")
DNS_FAILURES=$(grep -c "DNS lookup failed:" "$LOG_FILE")
CONNECT_FAILURES=$(grep -c "All connection attempts failed" "$LOG_FILE")
CONN_REFUSED=$(grep -c "Connection refused" "$LOG_FILE")
CONN_TIMEOUT=$(grep -c "Connection timed out" "$LOG_FILE")

if [[ $AP_CONNECT_ERRORS -gt 0 || $DNS_FAILURES -gt 0 || $CONNECT_FAILURES -gt 0 ]]; then
    echo "Connection issues detected:"
    if [[ $AP_CONNECT_ERRORS -gt 0 ]]; then
        echo "  AP connection errors: $AP_CONNECT_ERRORS"
    fi
    if [[ $DNS_FAILURES -gt 0 ]]; then
        echo -e "  ${RED}✗${NC} DNS lookup failures: $DNS_FAILURES"
    fi
    if [[ $CONNECT_FAILURES -gt 0 ]]; then
        echo -e "  ${RED}✗${NC} Connection attempts exhausted: $CONNECT_FAILURES"
    fi
    if [[ $CONN_REFUSED -gt 0 ]]; then
        echo "  Connection refused (errno 111): $CONN_REFUSED"
    fi
    if [[ $CONN_TIMEOUT -gt 0 ]]; then
        echo "  Connection timed out (errno 110): $CONN_TIMEOUT"
    fi
    
    # Show last AP connection attempt
    LAST_AP=$(grep "Connecting to Spotify AP:" "$LOG_FILE" | tail -1)
    if [[ -n "$LAST_AP" ]]; then
        echo ""
        echo "Last connection attempt:"
        echo "  $(echo "$LAST_AP" | sed 's/.*Connecting to Spotify AP: //')"
    fi
    
    # Show recent connection errors with details
    RECENT_CONN_ERRORS=$(grep "connect() failed for\|DNS lookup failed:\|All connection attempts failed" "$LOG_FILE" | tail -3)
    if [[ -n "$RECENT_CONN_ERRORS" ]]; then
        echo ""
        echo "Recent connection errors:"
        echo "$RECENT_CONN_ERRORS" | sed 's/^/  /g'
    fi
else
    echo -e "${GREEN}✓${NC} No connection issues detected"
fi
echo ""

# Performance metrics
echo "=== PERFORMANCE ==="
RATE_LOGS=$(grep "\[RATE-LIMIT\] Progress:" "$LOG_FILE" | tail -1)
if [[ -n "$RATE_LOGS" ]]; then
    echo "Latest rate limit status:"
    echo "  $(echo "$RATE_LOGS" | sed 's/.*Progress: //')"
fi

# Check for seek operations
SEEK_COUNT=$(grep -c "seeking from streamer\|Seeking\.\.\." "$LOG_FILE")
if [[ $SEEK_COUNT -gt 0 ]]; then
    echo "Seek operations: $SEEK_COUNT"
fi

# Check for large seeks (Vorbis codec probing)
LARGE_SEEKS=$(grep -c "\[VORBIS_SEEK\] Large forward seek" "$LOG_FILE")
if [[ $LARGE_SEEKS -gt 0 ]]; then
    echo "Large forward seeks: $LARGE_SEEKS (codec probing)"
fi
echo ""

# Configuration analysis
echo "=== CONFIGURATION ANALYSIS ==="

if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    echo "Configuration file: $CONFIG_FILE"
    echo ""
    echo "Configured values:"
    echo "  flow: ${CONFIG[flow]}"
    echo "  gapless: ${CONFIG[gapless]}"
    echo "  codec: ${CONFIG[codec]}"
    echo "  vorbis_rate: ${CONFIG[vorbis_rate]}"
    echo "  send_metadata: ${CONFIG[send_metadata]}"
    echo "  use_filecache: ${CONFIG[use_filecache]}"
    echo ""
fi

echo "Detected from logs:"

# Detect audio format
AUDIO_INFO=$(grep "Stream info: rate=" "$LOG_FILE" | head -1 | sed 's/.*Stream info: //')
if [[ -n "$AUDIO_INFO" ]]; then
    echo "  Audio format: $AUDIO_INFO"
fi

# Detect codec
CODEC_DETECTED=$(grep "Content-Type:" "$LOG_FILE" | head -1 | grep -oP 'Content-Type: \K[^ ]+')
if [[ -n "$CODEC_DETECTED" ]]; then
    echo "  Codec (Content-Type): $CODEC_DETECTED"
    
    # Consistency check
    if [[ -n "${CONFIG[codec]}" && "${CONFIG[codec]}" != "unknown" ]]; then
        if [[ "$CODEC_DETECTED" == *"${CONFIG[codec]}"* ]]; then
            echo -e "    ${GREEN}✓${NC} Matches config.xml"
        else
            echo -e "    ${YELLOW}⚠${NC} MISMATCH: config says '${CONFIG[codec]}' but detected '$CODEC_DETECTED'"
        fi
    fi
fi

# Detect bitrate
BITRATE=$(grep "bitrate_nominal=" "$LOG_FILE" | head -1 | grep -oP 'bitrate_nominal=\K[0-9]+')
if [[ -n "$BITRATE" ]]; then
    BITRATE_KBPS=$((BITRATE / 1000))
    echo "  Bitrate: ${BITRATE_KBPS}kbps"
    
    # Consistency check for vorbis rate
    if [[ -n "${CONFIG[vorbis_rate]}" && "${CONFIG[vorbis_rate]}" != "unknown" ]]; then
        if [[ "$BITRATE_KBPS" == "${CONFIG[vorbis_rate]}" ]]; then
            echo -e "    ${GREEN}✓${NC} Matches vorbis_rate in config.xml"
        else
            echo -e "    ${YELLOW}⚠${NC} MISMATCH: config vorbis_rate=${CONFIG[vorbis_rate]} but detected ${BITRATE_KBPS}kbps"
        fi
    fi
fi

# Flow mode consistency
if [[ -n "${CONFIG[flow]}" && "${CONFIG[flow]}" != "unknown" ]]; then
    echo ""
    echo "Flow mode consistency:"
    if [[ "${CONFIG[flow]}" == "1" ]]; then
        echo "  Config: flow=1 (ENABLED)"
        if [[ $FLOW_ACTIVE -gt 0 ]]; then
            echo -e "  ${GREEN}✓${NC} Flow mode is active in logs"
        elif [[ $DISCRETE_MODE -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠${NC} MISMATCH: Configured as enabled but running in discrete mode"
            echo "    This may be normal if the UPnP device doesn't support continuous streaming"
        fi
    else
        echo "  Config: flow=0 (DISABLED)"
        if [[ $DISCRETE_MODE -gt 0 ]]; then
            echo -e "  ${GREEN}✓${NC} Discrete mode confirmed in logs"
        elif [[ $FLOW_ACTIVE -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠${NC} MISMATCH: Configured as disabled but flow mode is active"
        fi
    fi
fi

# Gapless info
if [[ -n "${CONFIG[gapless]}" && "${CONFIG[gapless]}" != "unknown" ]]; then
    echo ""
    echo "Gapless configuration: ${CONFIG[gapless]} ($([ "${CONFIG[gapless]}" == "1" ] && echo "enabled" || echo "disabled"))"
    if [[ "${CONFIG[gapless]}" == "1" && "${CONFIG[flow]}" == "0" ]]; then
        echo "  ℹ Note: Gapless is enabled but flow is disabled - gapless requires flow mode"
    fi
fi

echo ""

# Session boundaries
echo "=== SESSION BOUNDARIES ==="
SESSION_STARTS=$(grep -c "========== PLAYBACK SESSION START ==========" "$LOG_FILE")
SESSION_ENDS=$(grep -c "========== PLAYBACK SESSION END ==========" "$LOG_FILE")
if [[ $SESSION_STARTS -gt 0 || $SESSION_ENDS -gt 0 ]]; then
    echo "Session starts: $SESSION_STARTS"
    echo "Session ends: $SESSION_ENDS"
else
    echo "No structured session markers found"
fi
echo ""

# SPIRC Protocol Analysis
echo "=== SPIRC PROTOCOL ANALYSIS ==="

# Count frame types
LOAD_FRAMES=$(grep -c "Load frame" "$LOG_FILE")
NOTIFY_FRAMES=$(grep -c "Notify frame" "$LOG_FILE")
PLAY_FRAMES=$(grep -c "Play frame" "$LOG_FILE")
PAUSE_FRAMES=$(grep -c "Pause frame" "$LOG_FILE")

echo "Frame types received from Spotify:"
echo "  Load frames: $LOAD_FRAMES"
echo "  Notify frames: $NOTIFY_FRAMES"
if [[ $PLAY_FRAMES -gt 0 ]]; then
    echo "  Play frames: $PLAY_FRAMES"
fi
if [[ $PAUSE_FRAMES -gt 0 ]]; then
    echo "  Pause frames: $PAUSE_FRAMES"
fi
echo ""

# Analyze PLAYBACK_START triggers
if [[ $SESSION_STARTS -gt 0 ]]; then
    echo "PLAYBACK_START event analysis:"
    echo "  Total PLAYBACK_START events: $SESSION_STARTS"
    echo "  Total Load frames: $LOAD_FRAMES"
    
    if [[ $LOAD_FRAMES -eq 1 && $SESSION_STARTS -gt 1 ]]; then
        QUEUED_TRACKS=$((SESSION_STARTS - 1))
        echo -e "  ${BLUE}ℹ${NC} Pattern detected: 1 Load frame initiated session, $QUEUED_TRACKS subsequent tracks auto-loaded from queue"
    elif [[ $LOAD_FRAMES -eq $SESSION_STARTS ]]; then
        echo -e "  ${BLUE}ℹ${NC} Each track was initiated by a separate Load frame (discrete mode)"
    elif [[ $LOAD_FRAMES -gt 0 && $LOAD_FRAMES -lt $SESSION_STARTS ]]; then
        echo -e "  ${BLUE}ℹ${NC} Mixed: $LOAD_FRAMES Load frames for $SESSION_STARTS tracks"
    fi
    
    # Show what triggered each PLAYBACK_START
    echo ""
    echo "Trigger details:"
    
    # Get timestamps of PLAYBACK_START and check what happened before each
    grep -n "========== PLAYBACK SESSION START ==========" "$LOG_FILE" | while IFS=: read -r line_num timestamp_line; do
        # Extract track number from context
        TRACK_NUM=$(grep -A2 "========== PLAYBACK SESSION START ==========" "$LOG_FILE" | grep "new track will start" | head -$((line_num/3+1)) | tail -1 | grep -oP 'start at \K[0-9]+')
        
        # Check for Load frame before this PLAYBACK_START
        CONTEXT_BEFORE=$(sed -n "$((line_num - 10)),$((line_num - 1))p" "$LOG_FILE" 2>/dev/null)
        
        if echo "$CONTEXT_BEFORE" | grep -q "Load frame"; then
            LOAD_INFO=$(echo "$CONTEXT_BEFORE" | grep "Load frame" | tail -1)
            echo -e "  Track $((line_num/3+1)): ${GREEN}Initiated by Spotify Load frame${NC}"
        elif echo "$CONTEXT_BEFORE" | grep -q "Got track ID="; then
            TRACK_ID=$(echo "$CONTEXT_BEFORE" | grep "Got track ID=" | tail -1 | grep -oP 'ID=\K[a-f0-9]+')
            echo -e "  Track $((line_num/3+1)): ${YELLOW}Auto-loaded from queue${NC} (trackId: ${TRACK_ID:0:12}...)"
        elif echo "$CONTEXT_BEFORE" | grep -q "Opening HTTP stream"; then
            echo -e "  Track $((line_num/3+1)): ${YELLOW}Auto-loaded from queue${NC} (CDN stream opened)"
        else
            echo -e "  Track $((line_num/3+1)): ${YELLOW}Queued track${NC}"
        fi
    done
fi
echo ""

# Summary statistics
echo "=== SUMMARY STATISTICS ==="
echo "Playback:"
echo "  Tracks played: $TRACK_COUNT"
if [[ ${#EXPECTED_TIMES[@]} -gt 0 ]]; then
    echo "  Tracks completed: ${#EXPECTED_TIMES[@]}"
fi
if [[ $FLOW_ACTIVE -gt 0 ]]; then
    echo -e "  Mode: ${GREEN}Flow (continuous)${NC}"
elif [[ $DISCRETE_MODE -gt 0 ]]; then
    echo -e "  Mode: ${RED}Discrete${NC}"
fi

echo ""
echo "Quality:"
ERROR_STATUS="${GREEN}OK${NC}"
if [[ $ERROR_COUNT -gt 0 ]]; then
    ERROR_STATUS="${RED}${ERROR_COUNT} errors${NC}"
fi
WARN_STATUS="${GREEN}OK${NC}"
if [[ $WARN_COUNT -gt 0 ]]; then
    WARN_STATUS="${YELLOW}${WARN_COUNT} warnings${NC}"
fi
echo -e "  Errors: $ERROR_STATUS"
echo -e "  Warnings: $WARN_STATUS"

if [[ ${#EXPECTED_TIMES[@]} -gt 0 ]]; then
    # Calculate average efficiency
    TOTAL_EXPECTED=0
    TOTAL_SLEPT=0
    for i in "${!EXPECTED_TIMES[@]}"; do
        EXPECTED=${EXPECTED_TIMES[$i]}
        SLEPT=${SLEPT_TIMES[$i]:-0}
        TOTAL_EXPECTED=$(awk "BEGIN {printf \"%.1f\", $TOTAL_EXPECTED + $EXPECTED}")
        TOTAL_SLEPT=$(awk "BEGIN {printf \"%.1f\", $TOTAL_SLEPT + $SLEPT}")
    done
    if [[ $(awk "BEGIN {print ($TOTAL_EXPECTED > 0)}") -eq 1 ]]; then
        AVG_EFFICIENCY=$(awk "BEGIN {printf \"%.1f\", ($TOTAL_SLEPT / $TOTAL_EXPECTED) * 100}")
        echo "  Rate limiting efficiency: ${AVG_EFFICIENCY}%"
    fi
fi

echo ""
echo "Configuration:"
if [[ -n "${CONFIG[flow]}" && "${CONFIG[flow]}" != "unknown" ]]; then
    FLOW_STATUS="flow=${CONFIG[flow]}"
    if [[ "${CONFIG[flow]}" == "1" && $FLOW_ACTIVE -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} $FLOW_STATUS (active)"
    elif [[ "${CONFIG[flow]}" == "0" && $DISCRETE_MODE -gt 0 ]]; then
        echo -e "  ${GREEN}✓${NC} $FLOW_STATUS (discrete mode)"
    elif [[ "${CONFIG[flow]}" == "1" && $DISCRETE_MODE -gt 0 ]]; then
        echo -e "  ${YELLOW}⚠${NC} $FLOW_STATUS (but running discrete)"
    else
        echo "  $FLOW_STATUS"
    fi
fi
if [[ -n "${CONFIG[codec]}" && "${CONFIG[codec]}" != "unknown" ]]; then
    echo "  codec=${CONFIG[codec]}"
fi
echo ""

echo "============================================"
echo "  ANALYSIS COMPLETE"
echo "============================================"
