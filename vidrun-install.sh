#!/usr/bin/env bash
set -euo pipefail

# === VidRun Installer (Ubuntu 24) - v2025-09-27 ===
# - Sets up /var/www/html/public_html + index.html (with VIDRUN markers, Copy + Delete buttons)
# - Nginx config with proper MIME types and WebDAV DELETE for *.mp4 in webroot
# - Installs scrollvid 1.7 (vertical default, left margin, change detection, verbose)
# - Safe to re-run

WEBROOT="/var/www/html/public_html"
INDEX="${WEBROOT}/index.html"
NGINX_SITE_NAME="vidrun"
STATE_DIR="/opt/vidrun/state"   # stores text checksums per output mp4

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root: sudo bash $0"; exit 1
  fi
}

apt_setup() {
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ffmpeg nginx curl wget jq unzip \
    fonts-dejavu-core ca-certificates \
    coreutils
}

prep_webroot() {
  mkdir -p "$WEBROOT" "$STATE_DIR"
  chown -R www-data:www-data "$WEBROOT"
  chmod -R 775 "$WEBROOT"

  if [[ ! -f "$INDEX" ]]; then
    cat > "$INDEX" <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>VidRun Outputs</title>
<style>
  body { font-family: system-ui,-apple-system,Segoe UI,Roboto,Arial,sans-serif; background:#0f1115; color:#e5e7eb; margin:2rem; }
  h1 { margin-bottom: 1rem; }
  table { width:100%; border-collapse:collapse; background:#151922; border-radius:12px; overflow:hidden; }
  th,td { padding:12px 14px; border-bottom:1px solid #2a2f3a; }
  th { text-align:left; background:#1a2030; }
  tr:hover { background:#181c28; }
  .btn { cursor:pointer; border:1px solid #2a2f3a; padding:6px 10px; border-radius:8px; background:#202637; color:#e5e7eb; }
  .btn-danger { border-color:#7a2a2a; background:#3a1f1f; }
  a { color:#80b3ff; }
  .actions { display:flex; gap:.5rem; }
</style>
</head>
<body>
  <h1>Generated MP4 Files</h1>
  <table id="mp4-table">
    <thead>
      <tr>
        <th>File</th>
        <th>URL</th>
        <th>Last Updated</th>
        <th>Actions</th>
      </tr>
    </thead>
    <tbody id="mp4-body">
    </tbody>
  </table>

<script>
(function () {
  const rows = [];

  // --- VIDRUN_MP4_ROWS_START ---
  // (rows get appended here by scrollvid.sh --html)
  // --- VIDRUN_MP4_ROWS_END ---

  const tbody = document.getElementById('mp4-body');
  function mkBtn(label, cls) {
    const b = document.createElement('button');
    b.className = 'btn ' + (cls||''); b.textContent = label; return b;
  }
  rows.forEach(r => {
    const tr = document.createElement('tr');
    const fileCell = document.createElement('td'); fileCell.textContent = r.file;
    const urlCell = document.createElement('td');
    const a = document.createElement('a'); a.href = r.url; a.textContent = r.url; a.target="_blank";
    urlCell.appendChild(a);
    const timeCell = document.createElement('td'); timeCell.textContent = r.updated;

    const actCell = document.createElement('td'); actCell.className = 'actions';
    const copyBtn = mkBtn('Copy');
    copyBtn.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(a.href); copyBtn.textContent = 'Copied!'; setTimeout(()=>copyBtn.textContent='Copy', 1500); }
      catch { alert('Copy failed'); }
    });

    const delBtn = mkBtn('Delete','btn-danger');
    delBtn.addEventListener('click', async () => {
      if (!confirm(`Delete ${r.file}?`)) return;
      // Issue HTTP DELETE to the file itself; Nginx DAV handles it
      try {
        const res = await fetch(a.href, { method: 'DELETE' });
        if (!res.ok && res.status !== 204) throw new Error('HTTP ' + res.status);
        tr.remove();
      } catch (e) {
        alert('Delete failed: ' + e);
      }
    });

    const wrap = document.createElement('div'); wrap.className = 'actions';
    wrap.append(copyBtn, delBtn); actCell.appendChild(wrap);

    tr.append(fileCell, urlCell, timeCell, actCell);
    tbody.appendChild(tr);
  });
})();
</script>
</body>
</html>
EOF
    chown www-data:www-data "$INDEX"
  fi
}

nginx_config() {
  # Nginx site with MIME types + WebDAV DELETE for mp4s in webroot
  cat > "/etc/nginx/sites-available/${NGINX_SITE_NAME}" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root ${WEBROOT};
    index index.html;

    server_name _;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Normal GETs
    location / {
        try_files \$uri \$uri/ =404;
    }

    # Allow DELETE for mp4 files only (WebDAV)
    location ~* \.mp4\$ {
        dav_methods DELETE;
        # Optional: restrict to local network by uncommenting:
        # allow 127.0.0.1;
        # allow 10.0.0.0/8;
        # deny all;
        try_files \$uri =404;
    }

    client_max_body_size 100M;
}
EOF

  # Disable default site, enable vidrun
  rm -f /etc/nginx/sites-enabled/default || true
  ln -snf "/etc/nginx/sites-available/${NGINX_SITE_NAME}" "/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx || true
}

install_scrollvid() {
  cat > /usr/local/bin/scrollvid.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_VERSION="scrollvid 1.7"

# Fail loud with line number
trap 's=$?; echo "[scrollvid] ERROR (exit $s) at line $LINENO"; exit $s' ERR

WEBROOT="/var/www/html/public_html"
INDEX="${WEBROOT}/index.html"
STATE_DIR="/opt/vidrun/state"     # store sha256 of last text per output

# Defaults
BG="#000000"; FG="#FFFFFF"
STROKE="#000000"; STROKEW="0"
FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONTSIZE="52"; SPEED="140"
WIDTH="1920"; HEIGHT="1080"
DURATION="60"
AUDIO=""; AUDIOVOL="1.0"
DO_HTML=false
VERBOSE=true
DEBUG=false
DIRECTION="vertical"      # default vertical scroll
LEFT_MARGIN="24"          # px; applies to vertical mode

usage() {
  cat <<USAGE
$SCRIPT_VERSION
Usage: $(basename "$0") <text_url> <output_mp4> [options]
  --bg '#000000'  --fg '#FFFF00'  --stroke-color '#000000'  --stroke-width N
  --font /path.ttf  --font-size N  --speed N  --width N  --height N  --duration N
  --audio /path.mp3  --audio-volume 0.8
  --html
  --quiet            (suppress ffmpeg logs)
  --debug            (bash -x)
  --direction vertical|horizontal
  --vertical | --horizontal
  --left-margin N    (px; vertical mode; default 24)
USAGE
  exit 1
}

echo "[$SCRIPT_VERSION] starting"

[[ $# -lt 2 ]] && usage
SRC_URL="$1"; shift
OUT_ARG="$1"; shift

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bg) BG="${2:-}"; shift 2 ;;
    --fg) FG="${2:-}"; shift 2 ;;
    --stroke-color) STROKE="${2:-}"; shift 2 ;;
    --stroke-width) STROKEW="${2:-}"; shift 2 ;;
    --font) FONT="${2:-}"; shift 2 ;;
    --font-size) FONTSIZE="${2:-}"; shift 2 ;;
    --speed) SPEED="${2:-}"; shift 2 ;;
    --width) WIDTH="${2:-}"; shift 2 ;;
    --height) HEIGHT="${2:-}"; shift 2 ;;
    --duration) DURATION="${2:-}"; shift 2 ;;
    --audio) AUDIO="${2:-}"; shift 2 ;;
    --audio-volume) AUDIOVOL="${2:-}"; shift 2 ;;
    --html) DO_HTML=true; shift ;;
    --quiet) VERBOSE=false; shift ;;
    --debug) DEBUG=true; shift ;;
    --direction) DIRECTION="${2:-}"; shift 2 ;;
    --vertical) DIRECTION="vertical"; shift ;;
    --horizontal) DIRECTION="horizontal"; shift ;;
    --left-margin) LEFT_MARGIN="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "[scrollvid] WARN: ignoring unknown option $1"; shift ;;
  esac
done

$DEBUG && set -x

# Deps
command -v ffmpeg >/dev/null || { echo "[scrollvid] ffmpeg missing"; exit 1; }
command -v curl   >/dev/null || { echo "[scrollvid] curl missing"; exit 1; }
test -r "$FONT" || { echo "[scrollvid] font missing: $FONT"; exit 1; }

# Output path
case "$OUT_ARG" in
  /*) OUT_MP4="$OUT_ARG" ;;
  *)  mkdir -p "$WEBROOT"; OUT_MP4="${WEBROOT}/${OUT_ARG}" ;;
esac
echo "[scrollvid] Output -> $OUT_MP4 (direction: $DIRECTION, left-margin: ${LEFT_MARGIN}px)"

# Strip leading '#'
strip_hash(){ printf "%s" "$1" | sed 's/^#//'; }
BG="$(strip_hash "$BG")"; FG="$(strip_hash "$FG")"; STROKE="$(strip_hash "$STROKE")"

# Workspace
WORKDIR="$(mktemp -d)"
TEXTFILE="${WORKDIR}/text.txt"
VID_NOSND="${WORKDIR}/video_nosnd.mp4"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[scrollvid] Downloading: $SRC_URL"
curl -fsSL "$SRC_URL" -o "$TEXTFILE"
test -s "$TEXTFILE" || { echo "[scrollvid] ERROR: downloaded text is empty"; exit 1; }

# CHANGE DETECTION — skip rendering if text unchanged since last run for this OUT_MP4
mkdir -p "$STATE_DIR"
SAFEKEY="$(basename "$OUT_MP4" | tr -c 'A-Za-z0-9._-' '_' )"
HASH_FILE="${STATE_DIR}/${SAFEKEY}.sha256"
NEW_HASH="$(sha256sum "$TEXTFILE" | awk '{print $1}')"
if [[ -f "$HASH_FILE" ]]; then
  OLD_HASH="$(cat "$HASH_FILE" 2>/dev/null || true)"
else
  OLD_HASH=""
fi

if [[ "$NEW_HASH" == "$OLD_HASH" ]]; then
  echo "[scrollvid] No changes in source text. Skipping render."
  exit 0
fi

echo "$NEW_HASH" > "$HASH_FILE"

# Prepare text according to direction
if [[ "$DIRECTION" == "horizontal" ]]; then
  paste -sd' | ' "$TEXTFILE" > "${TEXTFILE}.oneline"
  mv "${TEXTFILE}.oneline" "$TEXTFILE"
fi
# Vertical: keep line breaks for stacked lines

# Build filter (comma-free expressions using floor())
if [[ "$DIRECTION" == "vertical" ]]; then
  # Left margin and vertical scroll up:
  # x = LEFT_MARGIN
  # y = h - ( (t*SPEED) - ( (h+th) * floor( (t*SPEED) / (h+th) ) ) )
  X_EXPR="${LEFT_MARGIN}"
  Y_EXPR="h-((t*${SPEED})-((h+th)*floor((t*${SPEED})/(h+th))))"
  VF="drawtext=fontfile=${FONT}:fontsize=${FONTSIZE}:fontcolor=${FG}:textfile='${TEXTFILE}':x=${X_EXPR}:y=${Y_EXPR}:bordercolor=${STROKE}:borderw=${STROKEW}:box=0:line_spacing=10"
else
  # Horizontal marquee near bottom
  Y_POS="$(awk -v h="$HEIGHT" 'BEGIN{print (h>120? h-80 : h-40)}')"
  X_EXPR="w-((t*${SPEED})-((w+tw)*floor((t*${SPEED})/(w+tw))))"
  VF="drawtext=fontfile=${FONT}:fontsize=${FONTSIZE}:fontcolor=${FG}:textfile='${TEXTFILE}':x=${X_EXPR}:y=${Y_POS}:bordercolor=${STROKE}:borderw=${STROKEW}:box=0:line_spacing=10"
fi

echo "[scrollvid] Rendering ${WIDTH}x${HEIGHT} for ${DURATION}s (bg:#$BG fg:#$FG stroke:#$STROKE/$STROKEW)"
if $VERBOSE; then
  ffmpeg -hide_banner -y -f lavfi -i "color=c=${BG}:s=${WIDTH}x${HEIGHT}:d=${DURATION}" \
    -vf "$VF" -r 30 -pix_fmt yuv420p "$VID_NOSND"
else
  ffmpeg -hide_banner -y -f lavfi -i "color=c=${BG}:s=${WIDTH}x${HEIGHT}:d=${DURATION}" \
    -vf "$VF" -r 30 -pix_fmt yuv420p "$VID_NOSND" >/dev/null 2>&1
fi
test -s "$VID_NOSND" || { echo "[scrollvid] ERROR: video stage failed"; exit 1; }

# Audio (optional)
if [[ -n "$AUDIO" ]]; then
  if [[ -f "$AUDIO" ]]; then
    echo "[scrollvid] Muxing audio: $AUDIO (vol ${AUDIOVOL})"
    if $VERBOSE; then
      ffmpeg -hide_banner -y -stream_loop -1 -i "$AUDIO" -i "$VID_NOSND" \
        -shortest -filter:a "volume=${AUDIOVOL}" \
        -c:v copy -c:a aac -b:a 192k -movflags +faststart "$OUT_MP4"
    else
      ffmpeg -hide_banner -y -stream_loop -1 -i "$AUDIO" -i "$VID_NOSND" \
        -shortest -filter:a "volume=${AUDIOVOL}" \
        -c:v copy -c:a aac -b:a 192k -movflags +faststart "$OUT_MP4" >/dev/null 2>&1
    fi
  else
    echo "[scrollvid] WARN: audio file not found: $AUDIO (skipping)"
    mv "$VID_NOSND" "$OUT_MP4"
  fi
else
  mv "$VID_NOSND" "$OUT_MP4"
fi

# Finalize perms
chown www-data:www-data "$OUT_MP4" 2>/dev/null || true
chmod 664 "$OUT_MP4" 2>/dev/null || true
echo "[scrollvid] OK: wrote $OUT_MP4"

# Update index.html
if $DO_HTML; then
  FILE_NAME="$(basename "$OUT_MP4")"
  URL_PATH="/${FILE_NAME}"
  NOW="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  if [[ -f "$INDEX" ]] && grep -q 'VIDRUN_MP4_ROWS_START' "$INDEX"; then
    ROW_LINE="  rows.push({file: '$(printf "%s" "$FILE_NAME" | sed "s/'/\\\\'/g")', url: '$(printf "%s" "$URL_PATH" | sed "s/'/\\\\'/g")', updated: '$(printf "%s" "$NOW" | sed "s/'/\\\\'/g")'});"
    tmp="$(mktemp)"
    awk -v fn="$FILE_NAME" -v row="$ROW_LINE" '
      BEGIN { inblk=0 }
      /VIDRUN_MP4_ROWS_START/ { print; inblk=1; next }
      /VIDRUN_MP4_ROWS_END/   { if(inblk==1){ print row; inblk=0 } print; next }
      {
        if(inblk==1){
          if ($0 ~ "rows.push\\(\\{file: .*\\047" fn "\\047.*\\}\\);") next
          if ($0 ~ "rows.push\\(\\{file: .*\"" fn "\".*\\}\\);") next
        }
        print
      }
    ' "$INDEX" > "$tmp" && mv "$tmp" "$INDEX"
    chown www-data:www-data "$INDEX" 2>/dev/null || true
    echo "[scrollvid] Index updated for $FILE_NAME"
  else
    echo "[scrollvid] WARN: $INDEX missing VIDRUN markers; skipped HTML update."
  fi
fi

echo "[$SCRIPT_VERSION] done"
EOF

  chmod +x /usr/local/bin/scrollvid.sh
  hash -r || true
}

verify() {
  echo "== Quick checks =="
  which scrollvid.sh || true
  scrollvid.sh -h || true
  curl -sI http://127.0.0.1/ | head -n 5 || true
}

main() {
  require_root
  apt_setup
  prep_webroot
  nginx_config
  install_scrollvid
  verify
  cat <<MSG

=== Done ===
Web root:   $WEBROOT
Index page: $INDEX  (now includes Copy + Delete buttons)
Nginx site: /etc/nginx/sites-available/${NGINX_SITE_NAME}
Script:     /usr/local/bin/scrollvid.sh (scrollvid 1.7)

Examples:
  # Vertical (default) with 24px left margin
  sudo scrollvid.sh "https://myboxconfig.com/fixtures/MLB.txt" mlb.mp4 --html

  # Adjust left margin
  sudo scrollvid.sh "https://myboxconfig.com/fixtures/MLB.txt" mlb.mp4 --left-margin 40 --html

  # Horizontal marquee
  sudo scrollvid.sh "https://myboxconfig.com/fixtures/MLB.txt" mlb_horiz.mp4 --direction horizontal --html

Note:
- Delete button uses HTTP DELETE via Nginx WebDAV limited to *.mp4 under ${WEBROOT}.
- If your Nginx build lacks the DAV module, the Delete button will fail (fetch error).
  You can confirm DAV is active by deleting from CLI:
    curl -X DELETE http://127.0.0.1/mlb.mp4 -i
MSG
}

main "$@"
