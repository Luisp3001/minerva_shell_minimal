#!/bin/bash

# Watch the wallpaper directory for new files
WATCH_DIR="$HOME/wallpaper"
SCRIPT_TO_RUN="$HOME/.config/minerva_shell/components/Wallpaper/generate_thumbnails.sh"

# Ensure the directory exists
mkdir -p "$WATCH_DIR"

echo "Watching $WATCH_DIR for wallpaper changes..."

# We listen for close_write (file copied/downloaded), moved_to, delete, and moved_from
inotifywait -m -e close_write -e moved_to -e delete -e moved_from --format "%w%f" "$WATCH_DIR" | while read -r TARGET_FILE
do
    # Check if the file is an image
    case "$TARGET_FILE" in
        *.jpg|*.jpeg|*.png|*.webp)
            echo "Wallpaper change detected: $TARGET_FILE"
            # Give it a small delay in case the file is still being locked/written
            sleep 1
            # Run the thumbnail and tagger script
            bash "$SCRIPT_TO_RUN"
            ;;
    esac
done
