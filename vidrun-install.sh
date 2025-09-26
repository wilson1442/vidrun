sudo tee /usr/local/bin/scrollvid.sh >/dev/null <<'EOSV'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: scrollvid.sh <text_url_or_file> <output.mp4> [options]" >&2
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
SPEED=120
MARGIN=50
FONT_NAME="DejaVuSans-Bold.ttf"
AUDIO=""
AUDIO_VOL="1.0"
DURATION="60"
ALTCOLOR=""

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
    --html) shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# Ensure output directory exists
OUTDIR="$(dirname -- "$OUTPUT")"
mkdir -p "$OUTDIR"

# Resolve font file
FONT_PATH="$(fc-match -v "$FONT_NAME" 2>/dev/null | awk -F':' '/file:/ {gsub(/"/,""); gsub(/ /,""); print $2; exit}')"
[[ -z "${FONT_PATH:-}" || ! -f "$FONT_PATH" ]] && FONT_PATH="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

TMPDIR="$(mktemp -d -p /opt/scrollvid/tmp sv.XXXXXX)"
cleanup(){ rm -rf "$TMPDIR"; }
trap cleanup EXIT

TEXTFILE="$TMPDIR/text.txt"

# Load text
if [[ "$SOURCE" =~ ^https?:// ]]; then
  curl -fsSL "$SOURCE" -o "$TEXTFILE"
else
  cp "$SOURCE" "$TEXTFILE"
fi

# Clean and arrayify
awk NF "$TEXTFILE" | sed 's/^[ \t]*//;s/[ \t]*$//' > "$TMPDIR/clean.txt"
mapfile -t items < "$TMPDIR/clean.txt"
(( ${#items[@]} > 0 )) || { echo "No items to render." >&2; exit 1; }

join_with_bullets() {
  local -n arr=$1
  local out="" sep="   •   "
  for i in "${!arr[@]}"; do
    [[ $i -gt 0 ]] && out+="$sep"
    out+="${arr[$i]}"
  done
  printf "%s" "$out"
}

BASE_TEXT="$(join_with_bullets items)"

# Alternating masks (optional)
ODD_TEXT=""; EVEN_TEXT=""
if [[ -n "$ALTCOLOR" ]]; then
  placeholder=" "
  masked_odd=(); masked_even=()
  for i in "${!items[@]}"; do
    if (( i % 2 == 0 )); then masked_odd+=("${items[$i]}"); masked_even+=("$placeholder");
    else masked_odd+=("$placeholder"); masked_even+=("${items[$i]}"); fi
  done
  ODD_TEXT="$(join_with_bullets masked_odd)"
  EVEN_TEXT="$(join_with_bullets masked_even)"
fi

printf "%s" "$BASE_TEXT" > "$TMPDIR/base.txt"
if [[ -n "$ALTCOLOR" ]]; then
  printf "%s" "$ODD_TEXT"  > "$TMPDIR/odd.txt"
  printf "%s" "$EVEN_TEXT" > "$TMPDIR/even.txt"
fi

# Colors → 0xRRGGBB
norm_color(){ local c="$1"; [[ "$c" =~ ^#([0-9A-Fa-f]{6})$ ]] && echo "0x${c#\#}" || echo "$c"; }
BG_SAFE="$(norm_color "$BG")"
FG_SAFE="$(norm_color "$FG")"
STROKE_SAFE="$(norm_color "$STROKE_COLOR")"
ALTCOLOR_SAFE=""
[[ -n "$ALTCOLOR" ]] && ALTCOLOR_SAFE="$(norm_color "$ALTCOLOR")"

# Expressions (no spaces; escape comma)
x_expr="w-mod(t*${SPEED}\,w+tw)"
y_expr="h-(text_h+${MARGIN})"

draw_base="drawtext=fontfile=${FONT_PATH}:textfile=${TMPDIR}/base.txt:reload=1:fontcolor=${FG_SAFE}:fontsize=42:bordercolor=${STROKE_SAFE}:borderw=${STROKE_W}:x=${x_expr}:y=${y_expr}:line_spacing=6"
filters="$draw_base"

if [[ -n "$ALTCOLOR_SAFE" ]]; then
  draw_odd="drawtext=fontfile=${FONT_PATH}:textfile=${TMPDIR}/odd.txt:reload=1:fontcolor=${FG_SAFE}:fontsize=42:bordercolor=${STROKE_SAFE}:borderw=${STROKE_W}:x=${x_expr}:y=${y_expr}:line_spacing=6"
  draw_even="drawtext=fontfile=${FONT_PATH}:textfile=${TMPDIR}/even.txt:reload=1:fontcolor=${ALTCOLOR_SAFE}:fontsize=42:bordercolor=${STROKE_SAFE}:borderw=${STROKE_W}:x=${x_expr}:y=${y_expr}:line_spacing=6"
  filters="${draw_odd},${draw_even}"
fi

# Fallback if line_spacing unsupported
ff_try(){ ffmpeg -hide_banner -loglevel error -f lavfi -t 1 -i "color=c=${BG_SAFE}:s=64x64" -vf "$1" -frames:v 1 -f null - >/dev/null 2>&1; }
filter_full="format=yuv420p,${filters}"
ff_try "$filter_full" || filter_full="${filter_full/:line_spacing=6/}"

# Encode
if [[ -n "$AUDIO" ]]; then
  ffmpeg -hide_banner -y \
    -f lavfi -t "$DURATION" -i "color=c=${BG_SAFE}:s=${SIZE}" \
    -stream_loop -1 -i "$AUDIO" \
    -filter_complex "[0:v]${filter_full}[v];[1:a]volume=${AUDIO_VOL}[a]" \
    -map "[v]" -map "[a]" -shortest \
    -r "$FPS" -c:v libx264 -preset veryfast -pix_fmt yuv420p -movflags +faststart \
    "$OUTPUT"
else
  ffmpeg -hide_banner -y \
    -f lavfi -t "$DURATION" -i "color=c=${BG_SAFE}:s=${SIZE}" \
    -vf "${filter_full}" \
    -r "$FPS" -c:v libx264 -preset veryfast -pix_fmt yuv420p -movflags +faststart \
    "$OUTPUT"
fi

# Touch output to ensure mtime is current (index shows right time)
[[ -f "$OUTPUT" ]] && touch "$OUTPUT"

echo "✅ Wrote: $OUTPUT"
EOSV
sudo chmod +x /usr/local/bin/scrollvid.sh
