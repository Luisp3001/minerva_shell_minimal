#!/bin/bash
SRC_DIR="$HOME/wallpaper"
CACHE_DIR="$HOME/.cache/wallpaper"

mkdir -p "$CACHE_DIR"

for img in "$SRC_DIR"/*.{jpg,jpeg,png,webp}; do
    [ -f "$img" ] || continue
    filename=$(basename "$img")
    
    if [ ! -f "$CACHE_DIR/$filename" ]; then
        magick "$img" -resize "800x500" -gravity center "$CACHE_DIR/$filename"
        echo "Generated thumbnail: $filename"
    fi
done

# --- Cleanup logic ---
echo "Cleaning up old thumbnails..."
for thumb in "$CACHE_DIR"/*; do
    [ -f "$thumb" ] || continue
    thumb_name=$(basename "$thumb")

    # Skip non-image files (tags database, lock files, etc.)
    case "$thumb_name" in
        *.jpg|*.jpeg|*.png|*.webp|*.gif) ;;
        *) continue ;;
    esac
    
    if [ ! -f "$SRC_DIR/$thumb_name" ]; then
        rm "$thumb"
        echo "Removed old thumbnail: $thumb_name"
    fi
done

# --- Tag wallpapers with AI (runs in background) ---
TAGGER_SCRIPT="$(dirname "$0")/wallpaper_tagger.py"
if [ ! -f "$TAGGER_SCRIPT" ]; then
    TAGGER_SCRIPT="$(dirname "$0")/components/Wallpaper/wallpaper_tagger.py"
fi
if [ -f "$TAGGER_SCRIPT" ] && command -v ollama &>/dev/null; then
    # Don't launch if already running
    if pgrep -f "wallpaper_tagger.py" &>/dev/null; then
        echo "Wallpaper tagger already running, skipping."
    elif curl -s --max-time 3 http://localhost:11434/api/tags &>/dev/null; then
        echo "Starting wallpaper tagger in background..."
        OLLAMA_MODELS=/mnt/hdd/ollama/models python3 "$TAGGER_SCRIPT" &>/dev/null &
        disown
    fi
fi
