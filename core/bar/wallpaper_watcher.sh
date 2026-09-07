#!/bin/bash

# Watch the wallpaper directory for new files
WATCH_DIR="$HOME/wallpaper"
SCRIPT_TO_RUN="$HOME/.config/minerva_shell/core/bar/generate_thumbnails.sh"

# Ensure the directory exists
mkdir -p "$WATCH_DIR"

echo "Watching $WATCH_DIR for new wallpapers..."

# We listen for close_write (file copied/downloaded) and moved_to (file moved)
inotifywait -m -e close_write -e moved_to --format "%w%f" "$WATCH_DIR" | while read -r NEW_FILE
do
    # Check if the new file is an image or video
    case "$NEW_FILE" in
        *.jpg|*.jpeg|*.png|*.webp|*.gif|*.mp4|*.mkv|*.mov|*.webm)
            echo "New wallpaper detected: $NEW_FILE"
            # Give it a small delay in case the file is still being locked/written
            sleep 1
            # Run the thumbnail and tagger script
            bash "$SCRIPT_TO_RUN"
            ;;
    esac
done
