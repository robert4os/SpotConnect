#!/usr/bin/env python3
"""
Extract the last two complete song plays from spotupnp log file.
A complete song play starts with "Got track ID=" and ends with "Playing done".
"""

import sys
import re
import subprocess
from pathlib import Path

# ANSI escape code pattern (ESC is byte 0x1B which is octal 033)
# Match: ESC[...m (standard), ESC alone, or orphaned [...m at line start
ANSI_ESCAPE = re.compile(r'(\x1b\[[0-9;]*m|\x1b(?=\[)|^\[[0-9;]*m)', re.MULTILINE)


def extract_song_plays(log_file):
    """Extract all complete song plays from the log, tracking line indices."""
    with open(log_file, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    
    song_plays = []  # List of (start_idx, end_idx) tuples
    current_start = None
    in_song = False
    
    for i, line in enumerate(lines):
        # Start of a song play (track loading)
        if 'Got track ID=' in line or ('Track name:' in line and not in_song):
            if in_song and current_start is not None:
                # Save previous incomplete song if we're starting a new one
                song_plays.append((current_start, i - 1))
            current_start = i
            in_song = True
        elif in_song and 'Playing done' in line:
            # End of a song play
            song_plays.append((current_start, i))
            current_start = None
            in_song = False
    
    # Add last song if it was in progress (incomplete is ok for the last one)
    if current_start is not None:
        song_plays.append((current_start, len(lines) - 1))
    
    return lines, song_plays

def main():
    log_file = Path.home() / '.spotconnect' / 'spotupnp.log'
    output_file = Path('/tmp/sce.log')
    
    if not log_file.exists():
        print(f"Error: Log file not found: {log_file}")
        sys.exit(1)
    
    print(f"Reading log file: {log_file}")
    lines, song_plays = extract_song_plays(log_file)
    
    print(f"Found {len(song_plays)} song play(s)")
    
    if len(song_plays) < 2:
        print("Warning: Less than 2 complete song plays found")
        num_to_extract = len(song_plays)
    else:
        num_to_extract = 2
    
    # Extract last N complete songs
    last_songs = song_plays[-num_to_extract:]
    
    # Get continuous segment from first song start to last song end
    start_idx = last_songs[0][0]
    end_idx = last_songs[-1][1]
    
    # Add 10 lines before and after for context
    context_start = max(0, start_idx - 10)
    context_end = min(len(lines) - 1, end_idx + 10)
    
    # Write continuous log segment to output file (strip ANSI color codes)
    with open(output_file, 'w') as f:
        for line in lines[context_start:context_end + 1]:
            clean_line = ANSI_ESCAPE.sub('', line)
            f.write(clean_line)
    
    print(f"Extracted last {num_to_extract} song play(s) to: {output_file}")
    print(f"Log segment: lines {context_start} to {context_end} ({context_end - context_start + 1} lines)")
    print(f"  (includes 10 lines context before and after)")
    
    # Copy to clipboard
    try:
        subprocess.run(['xclip', '-selection', 'clipboard'], 
                      stdin=open(output_file, 'r'),
                      check=True)
        print("✓ Copied to clipboard")
    except FileNotFoundError:
        print("  (xclip not found - install with: sudo apt install xclip)")
    except Exception as e:
        print(f"  (Failed to copy to clipboard: {e})")
    
    # Print summary
    for i, (start, end) in enumerate(last_songs, 1):
        song_lines = lines[start:end + 1]
        # Try to find track name
        track_name = "Unknown"
        for line in song_lines[:50]:  # Check first 50 lines for track name
            if 'Track name:' in line:
                match = re.search(r'Track name:\s*(.+)', line)
                if match:
                    track_name = match.group(1).strip()
                    break
            elif 'new track id' in line and '=>' in line:
                match = re.search(r'=>\s*<(.+?)>', line)
                if match:
                    track_name = match.group(1).strip()
                    break
        
        # Find duration if available
        duration = "Unknown"
        for line in song_lines[:50]:
            if 'Track duration:' in line:
                match = re.search(r'Track duration:\s*(\d+)', line)
                if match:
                    dur_ms = int(match.group(1))
                    duration = f"{dur_ms/1000:.1f}s"
                    break
        
        # Check if completed
        completed = "COMPLETE" if any('Playing done' in line for line in song_lines) else "INCOMPLETE"
        
        print(f"  Song {i}: {track_name} ({duration}) - {completed}")

if __name__ == '__main__':
    main()
