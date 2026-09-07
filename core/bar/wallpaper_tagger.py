#!/usr/bin/env python3
"""
wallpaper_tagger.py — Generate tags for wallpapers using Ollama vision.

Uses gemma4:e2b to analyze wallpaper thumbnails and produce 8 descriptive
tags per image.  Results are stored in ~/.cache/wallpaper/tags.json so the
QML picker can filter by tag.

Usage:
    python3 wallpaper_tagger.py              # tag only new images
    python3 wallpaper_tagger.py --force      # re-tag everything
    python3 wallpaper_tagger.py --file X.jpg # tag a single file
"""

import argparse
import base64
import signal
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error

# ── Config ──────────────────────────────────────────────────────────────────
OLLAMA_URL    = "http://localhost:11434/api/generate"
MODEL         = "gemma4:e2b"
CACHE_DIR     = os.path.expanduser("~/.cache/wallpaper")
TAGS_FILE     = os.path.join(CACHE_DIR, "tags.json")
LOCK_FILE     = os.path.join(CACHE_DIR, "tagger.lock")
SRC_DIR       = os.path.expanduser("~/wallpaper")
IMAGE_EXTS    = {".jpg", ".jpeg", ".png", ".webp"}
TIMEOUT       = 90    # seconds per request
MAX_RETRIES   = 2

SYSTEM_PROMPT = """
You are a specialized image tagging assistant. Your sole task is to analyze the provided image and generate a list of descriptive tags in a strictly formatted JSON array of strings.

Rules for Tagging:
1. Content: Describe the main elements, objects, and setting of the image.
2. Mandatory Color: You must always identify and include the single most predominant color in the image as one of the tags.
3. Format: Output ONLY a JSON array of strings.
4. Constraint: Use a maximum of 8 tags per image.
5. Style: Use common, everyday words.
6. Casing: All tags must be in lowercase.
7. Punctuation: Do not use any punctuation or special characters within the tags.
8. Consistency: Be objective and consistent across different images.
9. No Prose: Do not provide any explanations, introductions, or closing remarks. Return ONLY the JSON.
""".strip()

USER_PROMPT = (
    "/no_think Generate exactly 8 short tags describing this wallpaper. "
    "Respond ONLY with a JSON array like [\"tag1\",\"tag2\",...]. No explanation."
)


# ── Locking ─────────────────────────────────────────────────────────────────
def acquire_lock():
    """Acquire a PID-file lock to prevent concurrent runs."""
    os.makedirs(CACHE_DIR, exist_ok=True)

    # Check if another instance is already running
    if os.path.isfile(LOCK_FILE):
        try:
            with open(LOCK_FILE, "r") as f:
                old_pid = int(f.read().strip())
            # Check if that PID is still alive
            os.kill(old_pid, 0)
            print(f"⚠ Another tagger (PID {old_pid}) is already running. Exiting.")
            sys.exit(0)
        except (ValueError, ProcessLookupError, PermissionError, OSError):
            # PID file is stale (process died), clean it up
            pass

    # Write our PID
    with open(LOCK_FILE, "w") as f:
        f.write(str(os.getpid()))


def release_lock():
    """Remove the PID lock file."""
    try:
        os.remove(LOCK_FILE)
    except OSError:
        pass


def check_ollama() -> bool:
    """Check if Ollama server is reachable."""
    try:
        req = urllib.request.Request("http://localhost:11434/api/tags")
        resp = urllib.request.urlopen(req, timeout=5)
        resp.read()
        return True
    except Exception:
        return False


# ── Tags DB ─────────────────────────────────────────────────────────────────
def load_tags_db() -> dict:
    """Load existing tags database."""
    if os.path.isfile(TAGS_FILE):
        try:
            with open(TAGS_FILE, "r") as f:
                data = json.load(f)
            if isinstance(data, dict):
                return data
        except (json.JSONDecodeError, IOError) as e:
            print(f"  ⚠ Corrupted tags.json, backing up: {e}", file=sys.stderr)
            # Backup corrupt file instead of losing it
            backup = TAGS_FILE + ".bak"
            try:
                os.replace(TAGS_FILE, backup)
            except OSError:
                pass
    return {}


def save_tags_db(db: dict):
    """Atomically save tags database (write to tmp, then rename)."""
    tmp = TAGS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(db, f, indent=2, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, TAGS_FILE)


# ── Image encoding ──────────────────────────────────────────────────────────
def encode_image(path: str) -> str:
    """Read and base64-encode an image file."""
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


# ── Tag parsing ─────────────────────────────────────────────────────────────
def parse_tags(content: str) -> list[str]:
    """Extract a list of tag strings from the model response."""
    content = content.strip()

    # Strip <think>...</think> blocks if present
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()

    if not content:
        return []

    # Try direct JSON parse
    try:
        tags = json.loads(content)
        if isinstance(tags, list):
            return [str(t).lower().strip() for t in tags if str(t).strip()][:8]
    except json.JSONDecodeError:
        pass

    # Try to find a JSON array in the text
    match = re.search(r"\[.*?\]", content, re.DOTALL)
    if match:
        try:
            tags = json.loads(match.group())
            if isinstance(tags, list):
                return [str(t).lower().strip() for t in tags if str(t).strip()][:8]
        except json.JSONDecodeError:
            pass

    # Last resort: split by commas
    raw = content.strip("[]\"'")
    parts = [p.strip().strip("\"'").lower() for p in raw.replace("\n", ",").split(",")]
    return [p for p in parts if p and len(p) < 30][:8]


# ── Ollama API ──────────────────────────────────────────────────────────────
def query_ollama(image_b64: str) -> list[str]:
    """Send image to Ollama and parse the tag list response."""
    payload = json.dumps({
        "model": MODEL,
        "system": SYSTEM_PROMPT,
        "prompt": USER_PROMPT,
        "images": [image_b64],
        "stream": False,
        "think": False,
        "options": {
            "temperature": 0.3,
            "num_predict": 150,
        },
    }).encode("utf-8")

    req = urllib.request.Request(
        OLLAMA_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
    )

    resp = urllib.request.urlopen(req, timeout=TIMEOUT)
    body = json.loads(resp.read())

    content = body.get("response", "").strip()
    # Fallback: some versions put content in thinking field
    if not content:
        content = body.get("thinking", "").strip()

    return parse_tags(content)


# ── File helpers ────────────────────────────────────────────────────────────
def get_wallpaper_files() -> list[str]:
    """List all wallpaper image files in the source directory."""
    files = []
    if not os.path.isdir(SRC_DIR):
        return files
    for name in sorted(os.listdir(SRC_DIR)):
        ext = os.path.splitext(name)[1].lower()
        if ext in IMAGE_EXTS:
            files.append(name)
    return files


def get_image_path(filename: str) -> str:
    """Get the best available image path (prefer cached thumbnail)."""
    thumb = os.path.join(CACHE_DIR, filename)
    if os.path.isfile(thumb):
        return thumb
    original = os.path.join(SRC_DIR, filename)
    if os.path.isfile(original):
        return original
    return ""


def tag_image(filename: str) -> list[str] | None:
    """Tag a single image with retries."""
    img_path = get_image_path(filename)
    if not img_path:
        print(f"  ✗ File not found: {filename}", file=sys.stderr)
        return None

    for attempt in range(1, MAX_RETRIES + 1):
        try:
            b64 = encode_image(img_path)
            tags = query_ollama(b64)
            if tags:
                return tags
            print(f"  ⚠ Empty tags (attempt {attempt})", file=sys.stderr)
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            print(f"  ⚠ Attempt {attempt} failed: {e}", file=sys.stderr)
        if attempt < MAX_RETRIES:
            time.sleep(2)

    return None


# ── Main ────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Tag wallpapers using Ollama vision")
    parser.add_argument("--force", action="store_true", help="Re-tag all images")
    parser.add_argument("--file", type=str, help="Tag a single file by name")
    args = parser.parse_args()

    # Prevent multiple concurrent instances
    acquire_lock()
    signal.signal(signal.SIGTERM, lambda *_: (release_lock(), sys.exit(0)))

    # Check Ollama is running
    if not check_ollama():
        print("✗ Ollama is not running. Start it with: ollama serve")
        sys.exit(1)

    os.makedirs(CACHE_DIR, exist_ok=True)
    db = load_tags_db()

    # Determine which files to process
    all_files = get_wallpaper_files()

    if args.file:
        files = [args.file]
    elif args.force:
        files = list(all_files)
    else:
        files = [f for f in all_files if f not in db]

    # Clean up stale entries (deleted wallpapers) — do this ALWAYS
    existing = set(all_files)
    removed = [k for k in list(db.keys()) if k not in existing]
    if removed:
        for k in removed:
            del db[k]
            print(f"  🗑 Removed stale: {k}")
        save_tags_db(db)

    if not files:
        print(f"✓ All {len(db)} wallpapers are already tagged.")
        release_lock()
        return

    total = len(files)
    tagged = 0
    failed = 0
    print(f"Tagging {total} wallpaper(s) with {MODEL}...")

    for i, filename in enumerate(files, 1):
        print(f"  [{i}/{total}] {filename}...", end=" ", flush=True)
        tags = tag_image(filename)
        if tags:
            db[filename] = tags
            tagged += 1
            print(f"→ {tags}")
            # Save after each successful tag
            save_tags_db(db)
        else:
            failed += 1
            print("✗ failed")

    print(f"\n✓ Done. {tagged} tagged, {failed} failed. Total: {len(db)} entries.")
    release_lock()


if __name__ == "__main__":
    main()
