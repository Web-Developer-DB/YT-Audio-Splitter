# YT-Audio-Splitter

# YT-Audio-Splitter – Audio Extraction & Segmentation with yt-dlp + FFmpeg

A lightweight Bash script that combines [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [FFmpeg](https://ffmpeg.org/) to extract audio from online videos and automatically split it into **chapters** or **time-based segments**. Works with single videos, playlists, and channel feeds – ideal for long DJ sets, lectures, or interviews.

---

## ⚖️ Legal Notice

This project is intended **for technical demonstration and educational purposes only**. Using yt-dlp to download content may violate the terms of service of certain platforms (e.g., YouTube). Always ensure you have the legal right to download and process any content before using this tool. Trademarks such as “YouTube” are the property of their respective owners and are mentioned here **descriptively only**. The authors accept **no liability** for third-party usage.

---

## ✨ Features

- Extracts **audio only** and converts it to **MP3** (default: 160 kbps)
- **Chapter-first**: If chapters exist, split precisely by chapter
- **Fallback**: If no chapters are available, audio is segmented into fixed lengths (default: 180s)
- Works with **videos, playlists, and channels**
- **Immediate post-processing** per file (Download → MP3 → Split)
- Metadata/chapters (if available) embedded into MP3s
- **Download archive** prevents duplicate downloads
- Optional **cookies** (e.g., for private or age-restricted content)
- Robust error handling (script continues even if one item fails)

---

## 🔧 Requirements

- Linux/WSL2 (tested with Ubuntu)
- yt-dlp (latest version recommended)
- ffmpeg + ffprobe
- Optional: python3 (better chapter parsing)

Install on Ubuntu/WSL2:

    sudo apt update
    sudo apt install -y yt-dlp ffmpeg python3

---

## 📦 Script File

Save the script as `yt.sh` and make it executable:

    chmod +x yt.sh

---

## ▶️ Quickstart

Download a playlist, convert to MP3, and auto-split:

    ./yt.sh --url "https://www.youtube.com/playlist?list=PLxxxx"

Process a single video:

    ./yt.sh --url "https://youtu.be/VIDEO_ID"

Use cookies (exported from Windows browser):

    ./yt.sh --url "https://www.youtube.com/playlist?list=PLxxxx" --cookies "/mnt/c/Users/NAME/Downloads/cookies.txt"

---

## ⚙️ Options

- `-u, --url <link>`  
  Video/Playlist/Channel link

- `-o, --out <dir>`  
  Output root (default: `~/YT-Audio`)

- `--br, --bitrate <kbps>`  
  MP3 bitrate (default: `160`)

- `--seg, --segment-seconds <sec>`  
  Segment length if no chapters are found (default: `180`)

- `--cookies <file>`  
  Path to cookies in Netscape format

- `--cookies-from-browser <spec>`  
  Extract cookies directly from browser (rarely works inside WSL2)

- `--no-geo-bypass`  
  Disable geo-bypass

Show help:

    ./yt.sh --help

---

## 📁 Output Structure (Examples)

Playlist:

    ~/YT-Audio/<Channel>/<Playlist>/<Title>/<Title>.mp3
    ~/YT-Audio/<Channel>/<Playlist>/<Title>/<Title>_ch_001 - <Chapter>.mp3
    ~/YT-Audio/<Channel>/<Playlist>/<Title>/<Title>_ch_002 - <Chapter>.mp3
    ...

Video without chapters:

    ~/YT-Audio/<Channel>/<Title>/<Title>_part_000.mp3
    ~/YT-Audio/<Channel>/<Title>/<Title>_part_001.mp3
    ...

---

## 🪟 WSL2 & Cookies

The option `--cookies-from-browser` usually does **not** work inside WSL2 because it cannot directly access Windows browser profiles. Instead, export cookies in Windows (e.g., with a "cookies.txt exporter") and use them in WSL via `/mnt/c/...`.

Example:

    ./yt.sh --url "..." --cookies "/mnt/c/Users/NAME/Downloads/cookies.txt"

---

## 🧪 More Examples

Extract only audio with default bitrate:

    ./yt.sh --url "https://youtu.be/VIDEO_ID"

Split into 2-minute segments:

    ./yt.sh --url "https://youtu.be/VIDEO_ID" --seg 120

Playlist with cookies:

    ./yt.sh --url "https://www.youtube.com/playlist?list=PLxxxx" --cookies "/mnt/c/Users/NAME/Downloads/cookies.txt"

Custom output directory:

    ./yt.sh --url "https://youtu.be/VIDEO_ID" --out "/data/audio"

---

## 🧰 Troubleshooting (Quick)

- “Sign in to confirm you’re not a bot” → Use cookies (see WSL2 note)
- No chapters detected → Fallback segments `_part_XXX.mp3` will be created
- Special characters in filenames → automatically sanitized
- Duplicate downloads → prevented via `download-archive.txt`

---

## 📜 License

MIT License – free to use and modify. Always respect platform terms of service and copyright laws.

---

## 🤝 Contributing

Feedback, issues, and pull requests are welcome. Suggestions for additional output formats (e.g., AAC/OPUS) or workflow improvements (e.g., parallelization, queuing, Dockerfile) are encouraged.
