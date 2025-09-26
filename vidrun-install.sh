#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ScrollVid / VidRun — CLEAN INSTALLER (Ubuntu 24.04 / Proxmox)
# ============================================================

(( EUID == 0 )) || { echo "Run as root: sudo bash $0"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

echo "[1/8] Install packages..."
apt-get update -y
apt-get install -y --no-install-recommends \
  ffmpeg curl jq ca-certificates unzip \
  fonts-dejavu-core fonts-dejavu-extra fontconfig \
  lynx html-xml-utils nginx

echo "[2/8] Install pup (CSS selector parser)..."
curl -fsSL https://github.com/ericchiang/pup/releases/download/v0.4.0/pup_v0.4.0_linux_amd64.zip -o /tmp/pup.zip
unzip -oq /tmp/pup.zip -d /usr/local/bin
chmod +x /usr/local/bin/pup
rm -f /tmp/pup.zip

echo "[3/8] Create app dirs..."
install -d -m 755 /opt/scrollvid/tmp
install -d -m 755 /var/log/scrollvid
install -d -m 755 /var/www/html/public_html
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

echo "[4/8] Write scripts..."

# ---------- scrollvid.sh (video generator; safe filtergraph) ----------
cat >/usr/local/bin/scrollvid.sh <<'EOSV'
#!/usr/bin/env bash
set -euo pipefail

# scrollvid.sh — scrolling ticker generator with safe FFmpeg filtergraph

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
    --html) shift ;; # no-op for compatibility
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

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
  placeholder=" "  # thin space
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

echo "✅ Wrote: $OUTPUT"
EOSV
chmod +x /usr/local/bin/scrollvid.sh

# ---------- html2list.sh (HTML capture helper) ----------
cat >/usr/local/bin/html2list.sh <<'EOH2L'
#!/usr/bin/env bash
set -euo pipefail

URL=""
SELECTOR=""
MAX_LINES=200
UA="Mozilla/5.0 (VidRunBot)"
OUT="/dev/stdout"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --selector) SELECTOR="$2"; shift 2 ;;
    --max-lines) MAX_LINES="$2"; shift 2 ;;
    --user-agent) UA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$URL" ]] || { echo "Usage: html2list.sh --url <URL> [--selector <CSS>]" >&2; exit 1; }

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

HTML="$TMPDIR/page.html"
curl -fsSL -A "$UA" "$URL" -o "$HTML"

if [[ -n "$SELECTOR" && -x "$(command -v pup || true)" ]]; then
  pup "${SELECTOR} text{}" < "$HTML" \
    | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//' \
    | awk 'NF' \
    | head -n "$MAX_LINES" \
    > "$OUT"
else
  lynx -dump -nolist -width=10000 "$URL" \
    | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//' \
    | awk 'NF' \
    | head -n "$MAX_LINES" \
    > "$OUT"
fi
EOH2L
chmod +x /usr/local/bin/html2list.sh

# ---------- build-index.sh (MP4-only table index) ----------
cat >/usr/local/bin/build-index.sh <<'SHX'
#!/usr/bin/env bash
set -euo pipefail

WEBROOT="/var/www/html/public_html"
OUT="${WEBROOT}/index.html"

mapfile -t FILES < <(find "$WEBROOT" -maxdepth 1 -type f -name "*.mp4" -printf "%f\n" | sort)

fmt_time(){ date -d "@$1" +"%Y-%m-%d %H:%M:%S"; }

ROWS=""
for f in "${FILES[@]}"; do
  [[ -n "$f" ]] || continue
  full="${WEBROOT}/${f}"
  mtime_epoch="$(stat -c %Y "$full" 2>/dev/null || stat -f %m "$full")"
  mtime_human="$(fmt_time "$mtime_epoch")"
  rel="./${f}"
  ROWS+=$(cat <<EOF
        <tr>
          <td class="name">${f}</td>
          <td class="url"><a href="${rel}" target="_blank" rel="noopener">${rel}</a></td>
          <td class="updated" data-epoch="${mtime_epoch}">${mtime_human}</td>
          <td class="actions"><button class="copy-btn" data-path="${rel}">Copy URL</button></td>
        </tr>
EOF
)
done

cat > "$OUT" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Public Videos</title>
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <style>
    :root { --bg:#0f1115; --fg:#eaeef2; --muted:#9aa4b2; --accent:#4da3ff; --row:#151923; --row2:#10131b; --border:#232839; }
    body{margin:0;background:var(--bg);color:var(--fg);font-family:ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,Arial,Noto Sans;}
    header{padding:20px 24px;border-bottom:1px solid var(--border);}
    h1{margin:0;font-size:20px;}
    main{padding:24px;}
    table{width:100%;border-collapse:collapse;}
    thead th{padding:10px 12px;text-align:left;font-size:12px;color:var(--muted);font-weight:600;border-bottom:1px solid var(--border);letter-spacing:.02em;text-transform:uppercase;}
    tbody td{padding:12px;border-bottom:1px solid var(--border);}
    tbody tr:nth-child(odd){background:var(--row);}
    tbody tr:nth-child(even){background:var(--row2);}
    a{color:var(--accent);text-decoration:none;} a:hover{text-decoration:underline;}
    .copy-btn{padding:6px 10px;background:#1a2333;color:var(--fg);border:1px solid var(--border);border-radius:8px;cursor:pointer;}
    .copy-btn:hover{background:#1f2a3d;}
    .hint,.footer{color:var(--muted);font-size:12px;margin-top:12px;}
    .name{font-weight:600;}
  </style>
</head>
<body>
  <header><h1>Public Videos</h1></header>
  <main>
    $( ((${#FILES[@]})) && echo '<table><thead><tr><th>Video</th><th>URL</th><th>Last Updated</th><th>Actions</th></tr></thead><tbody>' )
${ROWS}
    $( ((${#FILES[@]})) && echo '</tbody></table>' || echo '<div class="hint">No videos yet. They will appear here after the first run.</div>' )
    <div class="hint">Only <code>.mp4</code> files from <code>${WEBROOT}</code> are listed. HTML files are intentionally excluded.</div>
    <div class="footer">Generated: <span id="gen-ts"></span></div>
  </main>
  <script>
    document.getElementById('gen-ts').textContent = new Date().toLocaleString();
    document.querySelectorAll('.copy-btn').forEach(btn=>{
      btn.addEventListener('click', async ()=>{
        const rel = btn.getAttribute('data-path')||'';
        const url = new URL(rel, window.location.origin).href;
        try { await navigator.clipboard.writeText(url); btn.textContent='Copied!'; setTimeout(()=>btn.textContent='Copy URL',1200); }
        catch(e){ alert('Copy failed. URL: '+url); }
      });
    });
  </script>
</body>
</html>
EOF

echo "Wrote: $OUT"
SHX
chmod +x /usr/local/bin/build-index.sh

# ---------- vidrun.sh (runner; NO installs) ----------
cat >/root/vidrun.sh <<'SHR'
#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/scrollvid"
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/$(date +%F)_run.log"
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$RUN_LOG"; }

# Example job: MLB ticker
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

# Add more jobs by copying the block above and changing source/output/options.

log "All jobs complete."
/usr/local/bin/build-index.sh || log "Index build failed (non-fatal)."
SHR
chmod +x /root/vidrun.sh

echo "[5/8] Configure nginx site (serve /public_html, no default page)..."
# Remove default site
rm -f /etc/nginx/sites-enabled/default

# New site config
cat >/etc/nginx/sites-available/scrollvid.conf <<'NGX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;
    root /var/www/html/public_html;
    index index.html;

    # Serve static files (mp4, etc.). 404 if not found.
    location / {
        try_files $uri $uri/ =404;
    }

    # Larger files / streaming-friendly (tweak as needed)
    location ~* \.(mp4|m4v)$ {
        try_files $uri =404;
        # Add CORS if you embed externally:
        add_header Access-Control-Allow-Origin *;
        # Let clients resume downloads/seek:
        add_header Accept-Ranges bytes;
    }
}
NGX

ln -sf /etc/nginx/sites-available/scrollvid.conf /etc/nginx/sites-enabled/scrollvid.conf
nginx -t
systemctl enable nginx
systemctl restart nginx

echo "[6/8] Logrotate..."
cat >/etc/logrotate.d/scrollvid <<'EOLR'
/var/log/scrollvid/*.log {
  daily
  rotate 14
  compress
  missingok
  notifempty
  create 0640 root adm
}
EOLR

echo "[7/8] Cron schedule (every 15 minutes)..."
cat >/etc/cron.d/scrollvid <<'EOCRON'
*/15 * * * * root /bin/bash -lc '/root/vidrun.sh >> /var/log/scrollvid/scheduler.log 2>&1'
EOCRON
chmod 644 /etc/cron.d/scrollvid

echo "[8/8] First index build..."
/usr/local/bin/build-index.sh || true

echo
echo "============================================================"
echo "✅ Install complete."
echo "Site root:  /var/www/html/public_html   (http://<server-ip>/)"
echo "Runner:     /root/vidrun.sh             (cron @ */15 via /etc/cron.d/scrollvid)"
echo "Generator:  /usr/local/bin/scrollvid.sh"
echo "Scraper:    /usr/local/bin/html2list.sh"
echo "Indexer:    /usr/local/bin/build-index.sh"
echo "Logs:       /var/log/scrollvid/ (rotated daily)"
echo
echo "Quick test (5s, no audio):"
echo "ffmpeg -hide_banner -y -f lavfi -t 5 -i \"color=c=0x000000:s=1280x720\" -vf \"format=yuv420p,drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf:text='Hello World':fontcolor=0xFFFF00:fontsize=42:bordercolor=0x000000:borderw=3:x=w-mod(t*120\\,w+tw):y=h-(text_h+50):line_spacing=6\" /var/www/html/public_html/hello.mp4"
echo "Then open:  http://<server-ip>/  (you should NOT see the default nginx page)"
echo "============================================================"
