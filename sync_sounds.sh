#!/bin/bash
# Syncs .wav files from Proton Drive, with a local cache size limit.
# If the sounds folder exceeds MAX_CACHE_MB, oldest files are removed first.

SOUNDS_DIR="/home/doorbot/doorbot/sounds"
REMOTE_PATH="protondrive:sounds"
MAX_CACHE_MB=500

# Pull new sounds from Proton Drive (copy never deletes local files)
rclone copy "$REMOTE_PATH" "$SOUNDS_DIR"     --filter "+ *.wav"     --filter "- *"     --log-level WARNING

# Evict oldest .wav files if cache exceeds limit
CURRENT_KB=$(du -sk "$SOUNDS_DIR" | cut -f1)
MAX_KB=$((MAX_CACHE_MB * 1024))

while [ "$CURRENT_KB" -gt "$MAX_KB" ]; do
    # find oldest .wav by modification time, delete it
    OLDEST=$(find "$SOUNDS_DIR" -name '*.wav' -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-)
    if [ -z "$OLDEST" ]; then
        break
    fi
    rm -f "$OLDEST"
    CURRENT_KB=$(du -sk "$SOUNDS_DIR" | cut -f1)
done
