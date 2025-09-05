#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Purpose:
#   Extract audio from YouTube/YouTube Music using yt-dlp, save as MP3,
#   and robustly split the resulting file into chapters (if available)
#   or fixed-length segments as a fallback.
#
# Requirements:
#   - yt-dlp
#   - ffmpeg
#   - ffprobe (for chapter detection; fallback works without it)
#   - (optional) python3 for robust JSON parsing of ffprobe output
#
# Notes:
#   - WSL2: --cookies-from-browser usually does NOT work inside WSL.
#           Export cookies to a file (Netscape format) and use --cookies /mnt/c/...
#   - Download archive ($OUT_ROOT/download-archive.txt) prevents re-downloading
#     the same videos.
#   - The splitting helper script always exits 0 to avoid stopping yt-dlp jobs.
# -----------------------------------------------------------------------------

# Safety settings:
# -u: Treat unset variables as errors
# IFS: Restrict word-splitting to newline/tab (safer with spaces in names)
set -u
IFS=$'\n\t'

# --------- Defaults ---------
URL=""                      # Video/Playlist/Channel URL
OUT_ROOT="$HOME/YT-Audio"   # Output base directory
BITRATE_KBPS=160            # Target MP3 bitrate (kbit/s)
SEG_SEC=180                 # Segment length if no chapters are found
COOKIES_BROWSER=""          # e.g., "firefox" (rarely works in WSL)
COOKIES_FILE=""             # e.g., "/mnt/c/Users/<Name>/cookies.txt"
GEO_BYPASS=1                # 1=enabled, 0=disabled

# --------- CLI Parsing ---------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--url)                URL="$2"; shift 2;;
    -o|--out)                OUT_ROOT="$2"; shift 2;;
    --br|--bitrate)          BITRATE_KBPS="$2"; shift 2;;
    --seg|--segment-seconds) SEG_SEC="$2"; shift 2;;
    --cookies-from-browser)  COOKIES_BROWSER="$2"; shift 2;;
    --cookies)               COOKIES_FILE="$2"; shift 2;;
    --no-geo-bypass)         GEO_BYPASS=0; shift;;
    -h|--help)
      cat <<EOF
Usage: $0 --url <YouTube-URL> [options]

Options:
  -o, --out <dir>                  Target root (Default: $OUT_ROOT)
  --br, --bitrate <kbps>           MP3 Bitrate (Default: $BITRATE_KBPS)
  --seg, --segment-seconds <sec>   Segment length if no chapters (Default: $SEG_SEC)
  --cookies-from-browser <spec>    e.g., "firefox" (usually not working in WSL)
  --cookies <file>                 Path to cookies.txt (Netscape format)
  --no-geo-bypass                  Disable geo-bypass
  -h, --help                       Show this help
EOF
      exit 0;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

# Ask for URL interactively if not provided via CLI
if [[ -z "$URL" ]]; then
  read -rp "YouTube link (Video/Playlist/Channel): " URL
fi
[[ -z "$URL" ]] && { echo "No URL provided." >&2; exit 1; }

# --------- Check required tools ---------
for bin in yt-dlp ffmpeg ffprobe; do
  command -v "$bin" >/dev/null 2>&1 || { echo "MISSING: $bin" >&2; exit 1; }
done

# --------- URL kind detection ---------
# Simple heuristic to decide if the link is a video, playlist, or channel
get_url_kind() {
  local u="$1"
  [[ "$u" == *"list="* ]] && { echo playlist; return; }
  [[ "$u" == *"watch?v="* || "$u" == *"youtu.be/"* ]] && { echo video; return; }
  [[ "$u" == *"youtube.com/@"* || "$u" == *"youtube.com/channel/"* || "$u" == *"youtube.com/user/"* || "$u" == *"youtube.com/c/"* ]] && { echo channel; return; }
  echo unknown
}
KIND="$(get_url_kind "$URL")"
[[ "$KIND" == "unknown" ]] && { echo "Unknown link type." >&2; exit 1; }

mkdir -p "$OUT_ROOT"

# --------- Output Template ---------
# Defines folder structure and filename conventions for yt-dlp
# Playlist: Channel/Playlist/Title/Title.ext
# Single video: Channel/Title/Title.ext
if [[ "$KIND" == "playlist" ]]; then
  OUTPUT_TPL="%(channel,supplier,uploader)s/%(playlist_title,album,playlist_id)s/%(title)s/%(title)s.%(ext)s"
else
  OUTPUT_TPL="%(channel,supplier,uploader)s/%(title)s/%(title)s.%(ext)s"
fi


# --------- Helper Script (Splitting with FFmpeg) ---------
# This temporary script is executed after each download by yt-dlp (--exec).
# Responsibilities:
#   1) Detect chapters with ffprobe
#   2) Parse JSON reliably (prefer Python, fallback awk/csv)
#   3) Split audio into chapter files or fixed-length segments
#   4) Clean up original file after splitting
SPLITTER="$(mktemp /tmp/yt_split_mp3.XXXXXX.sh)"
cat >"$SPLITTER" <<'SH'
#!/usr/bin/env bash
set -u
export LC_ALL=C.UTF-8 LANG=C.UTF-8
IN=""; BR=160; S=180

logi(){ printf '[INFO] %s\n' "$*"; }
loge(){ printf '[ERROR] %s\n' "$*" >&2; }

# sanitize():
#  - Replaces illegal filename characters
#  - Ensures only printable characters
#  - Collapses duplicate underscores/spaces
#  - Limits to 120 characters
sanitize() {
  local s="$1"
  s="${s//\\/ _}"; s="${s//\//_}"; s="${s//:/_}"; s="${s//\*/_}"
  s="${s//\?/_}"; s="${s//\"/_}"; s="${s//</_}"; s="${s//>/_}"; s="${s//|/_}"
  s="$(echo -n "$s" | tr -cd '[:print:]')"
  s="$(echo -n "$s" | sed -E 's/[_ ]{2,}/_/g')"
  echo -n "${s:0:120}"
}

# Parse CLI args (passed by yt-dlp --exec)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)  IN="$2"; shift 2;;
    --br)  BR="$2"; shift 2;;
    --seg) S="$2"; shift 2;;
    *) shift;;
  esac
done
[[ -z "$IN" ]] && exit 0   # Never fail if no input file given

# --- Try to detect chapters with ffprobe ---
json="$(ffprobe -v error -print_format json -show_chapters -i "$IN" 2>/dev/null || true)"
have_chapters=0
if [[ -n "$json" && "$json" == *'"chapters":['* ]]; then
  have_chapters=1
fi

# Parse chapters into start|end|title format
if [[ $have_chapters -eq 1 ]]; then
  if command -v python3 >/dev/null 2>&1; then
    # Robust JSON parsing with Python
    if ! mapfile -t CH_LIST < <(printf '%s' "$json" | python3 - <<'PY'
import sys,json
try:
    data=json.load(sys.stdin)
    chs=data.get("chapters") or []
    for i,ch in enumerate(chs,1):
        st=float(ch.get("start_time") or ch.get("start") or 0.0)
        et=float(ch.get("end_time") or ch.get("end") or 0.0)
        if et<=st: 
            continue
        title=(ch.get("tags") or {}).get("title") or f"Chapter {i}"
        print(f"{st}|{et}|{title}")
except Exception:
    pass
PY
    ); then
      CH_LIST=()
    fi
  else
    # Fallback parsing without Python (less reliable if commas in titles)
    mapfile -t CH_LIST < <(ffprobe -v error -of csv=p=0 -show_entries chapter=start_time,end_time,tags/title "$IN" 2>/dev/null \
      | awk -F, 'NF>=2 {st=$1; et=$2; $1=""; $2=""; sub(/^,/, "", $0); print st "|" et "|" $0}')
  fi
else
  CH_LIST=()
fi

# Mode A: Split by chapters
if [[ ${#CH_LIST[@]} -gt 0 ]]; then
  DIR="$(dirname "$IN")"; BASE="$(basename "$IN" .mp3)"; idx=0
  logi "Chapters found – splitting by chapters..."
  for line in "${CH_LIST[@]}"; do
    st="${line%%|*}"; rest="${line#*|}"; et="${rest%%|*}"; title="${rest#*|}"
    idx=$((idx+1)); title_clean="$(sanitize "$title")"
    out="$DIR/${BASE}_ch_$(printf "%03d" "$idx") - ${title_clean}.mp3"
    ffmpeg -hide_banner -loglevel error -ss "$st" -to "$et" -i "$IN" -map a -c copy "$out"
  done
  rm -f -- "$IN"

# Mode B: No chapters → split into fixed segments
else
  DIR="$(dirname "$IN")"; BASE="$(basename "$IN" .mp3)"
  logi "No/invalid chapters – splitting into ${S}s parts..."
  ffmpeg -hide_banner -loglevel error -i "$IN" -f segment -segment_time "$S" -reset_timestamps 1 -map a -c copy \
    "$DIR/${BASE}_part_%03d.mp3"
  if ls "$DIR/${BASE}_part_"*.mp3 >/dev/null 2>&1; then
    rm -f -- "$IN"
  fi
fi

exit 0
SH
chmod +x "$SPLITTER"


# --------- yt-dlp Arguments ---------
YARGS=()
YARGS+=("$URL")

# Resilience flags:
# -c = resume partial downloads, -i = ignore errors, -w = skip existing
YARGS+=("-ciw")

# Output structure
YARGS+=("-P" "$OUT_ROOT")
YARGS+=("-o" "$OUTPUT_TPL")

# Download archive (avoid duplicates)
YARGS+=("--download-archive" "$OUT_ROOT/download-archive.txt")

# Audio extraction & conversion
YARGS+=("-f" "bestaudio/best")
YARGS+=("--extract-audio")
YARGS+=("--audio-format" "mp3")
YARGS+=("--audio-quality" "${BITRATE_KBPS}K")

# Metadata embedding
YARGS+=("--add-metadata")
YARGS+=("--embed-chapters")

# Avoid auxiliary files
YARGS+=("--no-write-playlist-metafiles")
YARGS+=("--no-write-description")
YARGS+=("--no-write-thumbnail")

# Clean names
YARGS+=("--no-part")
YARGS+=("--trim-filenames" "120")

# Extractor tweaks & retries
YARGS+=("--extractor-args" "youtube:player_client=android,web")
YARGS+=("--extractor-retries" "infinite")
YARGS+=("--retry-sleep" "1:10")
YARGS+=("--retries" "10")

# Geo bypass if enabled
[[ $GEO_BYPASS -eq 1 ]] && YARGS+=("--geo-bypass")

# For non-single videos (playlist/channel), process full playlist
[[ "$KIND" != "video" ]] && YARGS+=("--yes-playlist")

# Cookies setup (prefer file over browser)
if [[ -n "$COOKIES_FILE" ]]; then
  YARGS+=("--cookies" "$COOKIES_FILE")
elif [[ -n "$COOKIES_BROWSER" ]]; then
  YARGS+=("--cookies-from-browser" "$COOKIES_BROWSER")
fi

# --------- Exec command ---------
# yt-dlp replaces {} with downloaded file path
EXEC_STR="bash \"$SPLITTER\" --in {} --br $BITRATE_KBPS --seg $SEG_SEC"

echo "[INFO] Starting download..."
yt-dlp "${YARGS[@]}" --exec "$EXEC_STR"
RC=$?

echo "[INFO] Done. Output: $OUT_ROOT (yt-dlp RC=$RC)"
rm -f "$SPLITTER"
