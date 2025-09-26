#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ScrollVid: One-shot installer for Ubuntu 24.04 / Proxmox
# - Installs deps
# - Creates /usr/local/bin/scrollvid.sh
# - Creates /root/vudrun.sh (multi-job runner)
# - Sets up log directories + logrotate
# - Adds a cron schedule to run every 15 minutes
# ============================================================

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash install.sh"
  exit 1
fi

echo "[1/6] Updating apt and installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ffmpeg curl jq ca-certificates \
  fonts-dejavu-core fonts-dejavu-extra \
  fontconfig

echo "[2/6] Creating directories..."
install -d -m 755 /opt/scrollvid/tmp
install -d -m 755 /var/log/scrollvid

echo "[3/6] Installing /usr/local/bin/scrollvid.sh ..."
cat >/usr/local/bin/scrollvid.sh <<'EOSV'
#!/usr/bin/env bash
set -euo pipefail

# scrollvid.sh
# Generate a horizontal scrolling ticker video from a text source (URL or file)
# Usage:
#   scrollvid.sh "https://example.com/lines.txt" output.mp4 \
#     --bg '#000000' --fg '#FFFF00' --stroke-color '#000000' --stroke-width 3 \
#     --audio /path/to/audio.mp3 --audio-volume 0.8 --size 1920x1080 --fps 30 \
#     --speed 120 --margin 50 --font "DejaVuSans-Bold.ttf" --altcolors '#FF0000'
#
# Notes:
# - Input text can be a URL or a local file, one item per line.
# - Items are joined with a bullet (•) separator.
# - --altcolors lets you alternate item colors (even/odd) between --fg and that color.
# - Logs are placed in /var/log/scrollvid by caller (e.g., vudrun.sh).

if [[ $# -lt 2 ]]; then
  echo "Usage: scrollvid.sh <text_url_or_file> <output.mp4> [options]"
  exit 1
fi

SOURCE="$1"; shift
OUTPUT="$1"; shift

# Defaults
BG="#000000"
FG="#FFFF00"
STROKE_COLOR="#000000"
STROKE_W=3
SIZE="1920x1080"
FPS=30
SPEED=120          # pixels per second
MARGIN=50          # bottom margin for the ticker line
FONT_NAME="DejaVuSans-Bold.ttf"
AUDIO=""
AUDIO_VOL="1.0"
DURATION="60"      # seconds, if no audio; with audio we auto-shortest to audio
ALTCOLOR=""        # when set, alternates items between FG and ALTCOLOR

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bg) BG="$2"; shift 2 ;;
    --fg) FG="$2"; shift 2 ;;
    --stroke-color) STROKE_COLOR="$2"; shift 2 ;;
    --stroke-width) STROKE_W="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --fps) FPS="$2"; shift 2 ;;
    --speed) SPEED="$2"; shift 2 ;;
    --margin) MARGIN="$2"; shift 2 ;;
    --font) FONT_NAME="$2"; shift 2 ;;
    --audio) AUDIO="$2"; shift 2 ;;
    --audio-volume) AUDIO_VOL="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --altcolors) ALTCOLOR="$2"; shift 2 ;;
    --html)  # kept for compatibility; no-op here
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Resolve font path via fontconfig
FONT_PATH="$(fc-match -v "$FONT_NAME" 2>/dev/null | awk -F':' '/file:/ {gsub(/"/,""); gsub(/ /,""); print $2; exit}')"
if [[ -z "${FONT_PATH:-}" || ! -f "$FONT_PATH" ]]; then
  # fallback common path
  FONT_PATH="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
fi

TMPDIR="$(mktemp -d -p /opt/scrollvid/tmp sv.XXXXXX)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

TEXTFILE="$TMPDIR/text.txt"

# Fetch/prepare text
if [[ "$SOURCE" =~ ^https?:// ]]; then
  curl -fsSL "$SOURCE" -o "$TEXTFILE"
else
  cp "$SOURCE" "$TEXTFILE"
fi

# Normalize: remove empty lines & trim
awk NF "$TEXTFILE" | sed 's/^[ \t]*//;s/[ \t]*$//' > "$TMPDIR/clean.txt"

# Join items with bullet separator
# We also build two alternating strings (odd/even) to allow alternating colors.
items=()
while IFS= read -r line; do
  [[ -n "$line" ]] && items+=("$line")
done < "$TMPDIR/clean.txt"

if [[ ${#items[@]} -eq 0 ]]; then
  echo "No items to render." >&2
  exit 1
fi

join_with_bullets() {
  local -n arr=$1
  local out=""
  local sep="   •   "
  for i in "${!arr[@]}"; do
    [[ $i -gt 0 ]] && out+="$sep"
    out+="${arr[$i]}"
  done
  printf "%s" "$out"
}

# Build base ticker text
BASE_TEXT="$(join_with_bullets items)"

# When alt colors are requested, split into odd/even “masked” strings
ODD_TEXT=""
EVEN_TEXT=""
if [[ -n "$ALTCOLOR" ]]; then
  odd=()
  even=()
  for i in "${!items[@]}"; do
    if (( i % 2 == 0 )); then
      odd+=("${items[$i]}")
      even+=("")
    else
      odd+=("")
      even+=("${items[$i]}")
    fi
  done

  # To preserve spacing and separators, rebuild masked strings clueing positions
  # We map empty items to an invisible placeholder to keep separator spacing stable.
  # Here we use a thin space placeholder; drawtext will render it minimal.
  placeholder=" " # U+2009
  masked_odd=()
  masked_even=()
  for i in "${!items[@]}"; do
    if (( i % 2 == 0 )); then
      masked_odd+=("${items[$i]}")
      masked_even+=("$placeholder")
    else
      masked_odd+=("$placeholder")
      masked_even+=("${items[$i]}")
    fi
  done
  ODD_TEXT="$(join_with_bullets masked_odd)"
  EVEN_TEXT="$(join_with_bullets masked_even)"
fi

# Prepare safe text files for ffmpeg drawtext
printf "%s" "$BASE_TEXT" > "$TMPDIR/base.txt"
if [[ -n "$ALTCOLOR" ]]; then
  printf "%s" "$ODD_TEXT" > "$TMPDIR/odd.txt"
  printf "%s" "$EVEN_TEXT" > "$TMPDIR/even.txt"
fi

# Compose filter(s)
# Scrolling X: x = w - mod(t*speed, w+tw)
# Bottom Y:    y = h - (text_h + margin)
x_expr='w - mod(t*'"$SPEED"', w+tw)'
y_expr='h-(text_h+'"$MARGIN"')'

draw_base="drawtext=fontfile=${FONT_PATH}:textfile=${TMPDIR}/base.txt:reload=1:\
fontcolor=${FG}:fontsize=42:bordercolor=${STROKE_COLOR}:borderw=${STROKE_W}:\
x=${x_expr}:y=${y_expr}:line_spacing=6"

filters="$draw_base"

if [[ -n "$ALTCOLOR" ]]; then
  draw_odd="drawtext=fontfile=${FONT_PATH}:textfile=${TMPDIR}/odd.txt:reload=1:\
fontcolor=${FG}:fontsize=42:bordercolor=${STROKE_COLOR}:borderw=${STROKE_W}:\
x=${x_expr}:y=${y_expr}:line_spacing=6"
  draw_even="drawtext=fontfile=${FONT_PATH}:textfile=${TMPDIR}/even.txt:reload=1:\
fontcolor=${ALTCOLOR}:fontsize=42:bordercolor=${STROKE_COLOR}:borderw=${STROKE_W}:\
x=${x_expr}:y=${y_expr}:line_spacing=6"
  filters="${draw_odd},${draw_even}"
fi

# Build ffmpeg command
SIZE_ARG="$SIZE"
MAP_OPTS=()
FC="-vf format=yuv420p,${filters}"

if [[ -n "$AUDIO" ]]; then
  # Shortest to audio, and apply volume
  ffmpeg -hide_banner -y \
    -f lavfi -t "$DURATION" -i "color=c=${BG}:s=${SIZE_ARG}" \
    -stream_loop -1 -i "$AUDIO" \
    -filter_complex "[0:v]${filters}[v];[1:a]volume=${AUDIO_VOL}[a]" \
    -map "[v]" -map "[a]" -shortest \
    -r "$FPS" -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -movflags +faststart \
    "$OUTPUT"
else
  ffmpeg -hide_banner -y \
    -f lavfi -t "$DURATION" -i "color=c=${BG}:s=${SIZE_ARG}" \
    $FC -r "$FPS" -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -movflags +faststart \
    "$OUTPUT"
fi

echo "✅ Wrote: $OUTPUT"
EOSV
chmod +x /usr/local/bin/scrollvid.sh

echo "[4/6] Installing /root/vudrun.sh (multi-job runner) ..."
cat >/root/vudrun.sh <<'EORUN'
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/scrollvid"
mkdir -p "$LOG_DIR"

# Timestamped log per run
RUN_LOG="$LOG_DIR/$(date +%F)_run.log"

log() {
  echo "[$(date +'%F %T')] $*" | tee -a "$RUN_LOG"
}

# ------------------ Define your jobs below ------------------
# Each job: scrollvid.sh "<SOURCE_URL_OR_FILE>" "<OUTPUT_FILE>" [options...]
# Duplicate/modify blocks to add more videos.

# Example 1: MLB ticker
log "Starting job: mlb.mp4"
scrollvid.sh \
  "https://myboxconfig.com/fixtures/MLB.txt" \
  "/var/www/html/public_html/mlb.mp4" \
  --bg '#000000' \
  --fg '#FFFF00' \
  --stroke-color '#000000' \
  --stroke-width 3 \
  --audio "/var/www/html/public_html/audio.mp3" \
  --audio-volume 0.8 \
  --size 1920x1080 \
  --fps 30 \
  --speed 120 \
  --margin 50 \
  --altcolors '#00BFFF' \
  2>&1 | tee -a "$LOG_DIR/mlb.log"

# Example 2: (copy & customize)
# log "Starting job: nfl.mp4"
# scrollvid.sh \
#   "https://myboxconfig.com/fixtures/NFL.txt" \
#   "/var/www/html/public_html/nfl.mp4" \
#   --bg '#101010' \
#   --fg '#FFFFFF' \
#   --stroke-color '#000000' \
#   --stroke-width 3 \
#   --audio "/var/www/html/public_html/audio.mp3" \
#   --audio-volume 0.7 \
#   --size 1920x1080 \
#   --fps 30 \
#   --speed 140 \
#   --margin 60 \
#   2>&1 | tee -a "$LOG_DIR/nfl.log"

log "All jobs complete."
EORUN
chmod +x /root/vudrun.sh

echo "[5/6] Setting up logrotate for clean logs..."
cat >/etc/logrotate.d/scrollvid <<'EOLR'
/var/log/scrollvid/*.log {
  daily
  rotate 14
  compress
  missingok
  notifempty
  create 0640 root adm
  sharedscripts
  postrotate
    # Nothing needed; placeholder hook
    :
  endscript
}
EOLR

echo "[6/6] (Optional) Installing cron schedule every 15 minutes..."
# Drop a cron.d file to run the multi-job runner every 15 minutes
cat >/etc/cron.d/scrollvid <<'EOCRON'
# ScrollVid scheduler
*/15 * * * * root /bin/bash -lc '/root/vudrun.sh >> /var/log/scrollvid/scheduler.log 2>&1'
EOCRON
chmod 644 /etc/cron.d/scrollvid

echo
echo "============================================================"
echo "✅ Install complete."
echo
echo "Files & paths:"
echo "  • /usr/local/bin/scrollvid.sh     (video generator)"
echo "  • /root/vudrun.sh                 (multi-job runner — edit me)"
echo "  • /var/log/scrollvid/             (logs; auto-rotated)"
echo "  • /etc/cron.d/scrollvid           (runs every 15 minutes)"
echo
echo "Quick test (one-off):"
echo "  scrollvid.sh \"https://myboxconfig.com/fixtures/MLB.txt\" mlb_test.mp4 \\"
echo "    --bg '#000000' --fg '#FFFF00' --stroke-color '#000000' --stroke-width 3 \\"
echo "    --audio /var/www/html/public_html/audio.mp3 --audio-volume 0.8"
echo
echo "Edit /root/vudrun.sh to add more jobs. Logs will remain tidy via logrotate."
echo "============================================================"
