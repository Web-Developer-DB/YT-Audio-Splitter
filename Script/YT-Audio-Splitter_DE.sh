#!/usr/bin/env bash
# Requires: yt-dlp, ffmpeg, ffprobe (optional: python3)
# WSL2-Hinweis: --cookies-from-browser funktioniert i.d.R. NICHT in WSL.
#               Exportiere Cookies als Datei und nutze --cookies /mnt/c/...


set -u
IFS=$'\n\t'

# --------- Defaults ---------
URL=""
OUT_ROOT="$HOME/YT-Audio"
BITRATE_KBPS=160
SEG_SEC=180
COOKIES_BROWSER=""   # z.B. "firefox" (in WSL meist wirkungslos)
COOKIES_FILE=""      # z.B. "/mnt/c/Users/<Name>/cookies.txt"
GEO_BYPASS=1         # 1=an, 0=aus

# --------- CLI-Parsing ---------
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
  -o, --out <dir>                  Zielwurzel (Default: $OUT_ROOT)
  --br, --bitrate <kbps>           MP3 Bitrate (Default: $BITRATE_KBPS)
  --seg, --segment-seconds <sec>   Segmentlänge ohne Kapitel (Default: $SEG_SEC)
  --cookies-from-browser <spec>    z.B. "firefox" (in WSL meist nicht nutzbar)
  --cookies <file>                 Pfad zu cookies.txt (Netscape-Format)
  --no-geo-bypass                  Geo-Bypass deaktivieren
  -h, --help                       Hilfe anzeigen
EOF
      exit 0;;
    *) echo "Unbekannte Option: $1" >&2; exit 1;;
  esac
done

if [[ -z "$URL" ]]; then
  read -rp "YouTube-Link (Video/Playlist/Kanal): " URL
fi
[[ -z "$URL" ]] && { echo "Keine URL angegeben." >&2; exit 1; }

# --------- Tools prüfen ---------
for bin in yt-dlp ffmpeg ffprobe; do
  command -v "$bin" >/dev/null 2>&1 || { echo "FEHLT: $bin" >&2; exit 1; }
done

# --------- URL-Typ ---------
get_url_kind() {
  local u="$1"
  [[ "$u" == *"list="* ]] && { echo playlist; return; }
  [[ "$u" == *"watch?v="* || "$u" == *"youtu.be/"* ]] && { echo video; return; }
  [[ "$u" == *"youtube.com/@"* || "$u" == *"youtube.com/channel/"* || "$u" == *"youtube.com/user/"* || "$u" == *"youtube.com/c/"* ]] && { echo channel; return; }
  echo unknown
}
KIND="$(get_url_kind "$URL")"
[[ "$KIND" == "unknown" ]] && { echo "Unbekannter Linktyp." >&2; exit 1; }

mkdir -p "$OUT_ROOT"

# --------- Output-Template ---------
if [[ "$KIND" == "playlist" ]]; then
  OUTPUT_TPL="%(channel,supplier,uploader)s/%(playlist_title,album,playlist_id)s/%(title)s/%(title)s.%(ext)s"
else
  OUTPUT_TPL="%(channel,supplier,uploader)s/%(title)s/%(title)s.%(ext)s"
fi


# --------- Helper-Skript (FFmpeg-Splitting, robust) ---------
SPLITTER="$(mktemp /tmp/yt_split_mp3.XXXXXX.sh)"
cat >"$SPLITTER" <<'SH'
#!/usr/bin/env bash
set -u
export LC_ALL=C.UTF-8 LANG=C.UTF-8
IN=""; BR=160; S=180

# --- kleine Logs ---
logi(){ printf '[INFO] %s\n' "$*"; }
loge(){ printf '[ERROR] %s\n' "$*" >&2; }

sanitize() {
  local s="$1"
  s="${s//\\/ _}"; s="${s//\//_}"; s="${s//:/_}"; s="${s//\*/_}"
  s="${s//\?/_}"; s="${s//\"/_}"; s="${s//</_}"; s="${s//>/_}"; s="${s//|/_}"
  s="$(echo -n "$s" | tr -cd '[:print:]')"
  s="$(echo -n "$s" | sed -E 's/[_ ]{2,}/_/g')"
  echo -n "${s:0:120}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in)  IN="$2"; shift 2;;
    --br)  BR="$2"; shift 2;;
    --seg) S="$2"; shift 2;;
    *) shift;;
  esac
done
[[ -z "$IN" ]] && exit 0   # nie yt-dlp stoppen

# --- Kapitel versuchen ---
json="$(ffprobe -v error -print_format json -show_chapters -i "$IN" 2>/dev/null || true)"
have_chapters=0
if [[ -n "$json" && "$json" == *'"chapters":['* ]]; then
  have_chapters=1
fi

if [[ $have_chapters -eq 1 ]]; then
  # versuchen mit python3 sauber zu parsen
  if command -v python3 >/dev/null 2>&1; then
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
        title=(ch.get("tags") or {}).get("title") or f"Kapitel {i}"
        print(f"{st}|{et}|{title}")
except Exception:
    # leise scheitern -> kein Kapitelmodus
    pass
PY
    ); then
      CH_LIST=()
    fi
  else
    # Fallback ohne Python (ungenau bei Kommas im Titel)
    mapfile -t CH_LIST < <(ffprobe -v error -of csv=p=0 -show_entries chapter=start_time,end_time,tags/title "$IN" 2>/dev/null \
      | awk -F, 'NF>=2 {st=$1; et=$2; $1=""; $2=""; sub(/^,/, "", $0); print st "|" et "|" $0}')
  fi
else
  CH_LIST=()
fi

if [[ ${#CH_LIST[@]} -gt 0 ]]; then
  DIR="$(dirname "$IN")"; BASE="$(basename "$IN" .mp3)"; idx=0
  logi "Kapitel gefunden – splitte nach Kapiteln…"
  for line in "${CH_LIST[@]}"; do
    st="${line%%|*}"; rest="${line#*|}"; et="${rest%%|*}"; title="${rest#*|}"
    idx=$((idx+1)); title_clean="$(sanitize "$title")"
    out="$DIR/${BASE}_ch_$(printf "%03d" "$idx") - ${title_clean}.mp3"
    ffmpeg -hide_banner -loglevel error -ss "$st" -to "$et" -i "$IN" -map a -c copy "$out"
  done
  rm -f -- "$IN"
else
  # --- Fallback: 3-Minuten-Segmente ---
  DIR="$(dirname "$IN")"; BASE="$(basename "$IN" .mp3)"
  logi "Keine/ungültige Kapitel – splitte in ${S}s-Teile…"
  ffmpeg -hide_banner -loglevel error -i "$IN" -f segment -segment_time "$S" -reset_timestamps 1 -map a -c copy \
    "$DIR/${BASE}_part_%03d.mp3"
  if ls "$DIR/${BASE}_part_"*.mp3 >/dev/null 2>&1; then
    rm -f -- "$IN"
  fi
fi

exit 0
SH
chmod +x "$SPLITTER"


# --------- yt-dlp Argumente sauber als Array ---------
YARGS=()
YARGS+=("$URL")
YARGS+=("-ciw")
YARGS+=("-P" "$OUT_ROOT")
YARGS+=("-o" "$OUTPUT_TPL")
YARGS+=("--download-archive" "$OUT_ROOT/download-archive.txt")
YARGS+=("-f" "bestaudio/best")
YARGS+=("--extract-audio")
YARGS+=("--audio-format" "mp3")
YARGS+=("--audio-quality" "${BITRATE_KBPS}K")
YARGS+=("--add-metadata")
YARGS+=("--embed-chapters")
YARGS+=("--no-write-playlist-metafiles")
YARGS+=("--no-write-description")
YARGS+=("--no-write-thumbnail")
YARGS+=("--no-part")
YARGS+=("--trim-filenames" "120")
YARGS+=("--extractor-args" "youtube:player_client=android,web")
YARGS+=("--extractor-retries" "infinite")
YARGS+=("--retry-sleep" "1:10")
YARGS+=("--retries" "10")
[[ $GEO_BYPASS -eq 1 ]] && YARGS+=("--geo-bypass")
[[ "$KIND" != "video" ]] && YARGS+=("--yes-playlist")

# Cookies: in WSL bevorzugt Datei nutzen
if [[ -n "$COOKIES_FILE" ]]; then
  YARGS+=("--cookies" "$COOKIES_FILE")
elif [[ -n "$COOKIES_BROWSER" ]]; then
  # Hinweis: in WSL meist nicht möglich; lass es dennoch optional zu
  YARGS+=("--cookies-from-browser" "$COOKIES_BROWSER")
fi

# --------- Exec-Command (Pfad liefert yt-dlp als '{}') ---------
EXEC_STR="bash \"$SPLITTER\" --in {} --br $BITRATE_KBPS --seg $SEG_SEC"

echo "[INFO] Starte Download…"
yt-dlp "${YARGS[@]}" --exec "$EXEC_STR"
RC=$?

echo "[INFO] Fertig. Ausgabe: $OUT_ROOT (yt-dlp RC=$RC)"
rm -f "$SPLITTER"

