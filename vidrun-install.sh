#!/usr/bin/env bash
set -euo pipefail

# === VidRun one-shot installer for Ubuntu 24 ===
# - Installs deps (ffmpeg, nginx, fonts, etc.)
# - Creates /var/www/html/public_html
# - Configures Nginx to serve that folder
# - Installs scrollvid.sh into /usr/local/bin (PATH) and makes it executable

REPO_SCROLLVID_URL="https://raw.githubusercontent.com/wilson1442/vidrun/refs/heads/main/scrollvid.sh"
WEBROOT="/var/www/html/public_html"
NGINX_SITE_NAME="vidrun"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root (sudo bash $0)"; exit 1
  fi
}

apt_setup() {
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ffmpeg nginx curl wget jq unzip \
    fonts-dejavu-core ca-certificates
}

prep_webroot() {
  mkdir -p "$WEBROOT"
  chown -R www-data:www-data "$WEBROOT"
  chmod -R 775 "$WEBROOT"

  # Drop a minimal index.html if missing (we’ll ONLY list MP4 links here)
  if [[ ! -f "$WEBROOT/index.html" ]]; then
    cat > "$WEBROOT/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>VidRun Outputs</title>
<style>
  body { font-family: system-ui, -apple-system, Segoe UI, Roboto, Arial, sans-serif; background:#0f1115; color:#e5e7eb; margin: 2rem; }
  h1 { margin-bottom: 1rem; }
  table { width:100%; border-collapse: collapse; background:#151922; border-radius:12px; overflow:hidden; }
  th, td { padding: 12px 14px; border-bottom: 1px solid #2a2f3a; }
  th { text-align:left; background:#1a2030; }
  tr:hover { background:#181c28; }
  .btn { cursor:pointer; border:1px solid #2a2f3a; padding:6px 10px; border-radius:8px; background:#202637; color:#e5e7eb; }
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
        <th>Copy URL</th>
      </tr>
    </thead>
    <tbody id="mp4-body">
    </tbody>
  </table>

<script>
(function () {
  const rows = [];

  // The installer keeps/updates this block. Do not remove the markers.
  // --- VIDRUN_MP4_ROWS_START ---
  // (rows get appended here by scrollvid.sh --html)
  // --- VIDRUN_MP4_ROWS_END ---

  const tbody = document.getElementById('mp4-body');
  rows.forEach(r => {
    const tr = document.createElement('tr');
    const fileCell = document.createElement('td'); fileCell.textContent = r.file;
    const urlCell = document.createElement('td');
    const a = document.createElement('a'); a.href = r.url; a.textContent = r.url; a.style.color = "#80b3ff"; a.target="_blank";
    urlCell.appendChild(a);
    const timeCell = document.createElement('td'); timeCell.textContent = r.updated;
    const copyCell = document.createElement('td');
    const btn = document.createElement('button'); btn.className = 'btn'; btn.textContent = 'Copy';
    btn.addEventListener('click', async () => {
      try { await navigator.clipboard.writeText(r.url); btn.textContent = 'Copied!'; setTimeout(()=>btn.textContent='Copy',1500); }
      catch (e) { alert('Copy failed'); }
    });
    copyCell.appendChild(btn);
    tr.append(fileCell, urlCell, timeCell, copyCell);
    tbody.appendChild(tr);
  });
})();
</script>
</body>
</html>
EOF
    chown www-data:www-data "$WEBROOT/index.html"
  fi
}

nginx_config() {
  # Write site config to serve WEBROOT
  cat > "/etc/nginx/sites-available/${NGINX_SITE_NAME}" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root ${WEBROOT};
    index index.html;

    server_name _;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Serve mp4 with proper types
    types {
        video/mp4 mp4;
    }

    client_max_body_size 100M;
}
EOF

  # Disable default if exists, enable our site
  if [[ -L /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  ln -sf "/etc/nginx/sites-available/${NGINX_SITE_NAME}" "/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx || true
}

install_scrollvid() {
  local target="/usr/local/bin/scrollvid.sh"
  echo "Installing scrollvid.sh to ${target}"

  # Try to download the maintained version first
  if curl -fsSL "$REPO_SCROLLVID_URL" -o "$target"; then
    echo "Downloaded scrollvid.sh from repo."
  else
    echo "WARN: Could not download scrollvid.sh from repo. Installing a fallback wrapper."
    # Minimal fallback wrapper that:
    # - runs the GitHub version if available later
    # - ensures --html updates index.html table rows safely
    cat > "$target" <<'FALLBACK'
#!/usr/bin/env bash
set -euo pipefail

WEBROOT="/var/www/html/public_html"
INDEX="${WEBROOT}/index.html"
NOW="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"

usage() {
  echo "Usage: scrollvid.sh <source_text_url> <output_mp4> [--html] [other args passed to upstream]"
  exit 1
}

[[ $# -lt 2 ]] && usage

SRC_URL="$1"; shift
OUT_ARG="$1"; shift

DO_HTML=false
for a in "$@"; do
  [[ "$a" == "--html" ]] && DO_HTML=true
done

# Ensure absolute output path: if user passed a bare name (e.g., mlb.mp4), save it under WEBROOT.
case "$OUT_ARG" in
  /*) OUT_MP4="$OUT_ARG" ;;
  *)  OUT_MP4="${WEBROOT}/${OUT_ARG}" ;;
esac

mkdir -p "$WEBROOT"

# Attempt to fetch and exec the upstream script if present at runtime.
UPSTREAM="/opt/vidrun/scrollvid.sh"
if [[ -x "$UPSTREAM" ]]; then
  # Run upstream with adjusted output path
  "$UPSTREAM" "$SRC_URL" "$OUT_MP4" "$@"
else
  # No upstream available; just touch an empty mp4 so the web listing still works.
  echo "Upstream scrollvid not found; creating placeholder mp4 at $OUT_MP4"
  : > "$OUT_MP4"
fi

chown www-data:www-data "$OUT_MP4" || true
chmod 664 "$OUT_MP4" || true

if $DO_HTML; then
  # Safely insert/update an entry in index.html's rows block
  FILE_NAME="$(basename "$OUT_MP4")"
  URL_PATH="/${FILE_NAME}"
  # Create a JS object literal line:
  ROW_LINE="  rows.push({file: ${FILE_NAME@Q}, url: ${URL_PATH@Q}, updated: ${NOW@Q}});"

  # Ensure markers exist
  if ! grep -q 'VIDRUN_MP4_ROWS_START' "$INDEX"; then
    echo "ERROR: index.html does not contain VIDRUN markers; refusing to edit."
    exit 0
  fi

  # Remove any existing line for this file (idempotent update), then append
  tmp="$(mktemp)"
  awk -v fn="$FILE_NAME" '
    BEGIN{inblk=0}
    /VIDRUN_MP4_ROWS_START/ {inblk=1; print; next}
    /VIDRUN_MP4_ROWS_END/   {inblk=0; print; next}
    {
      if(inblk==1){
        if ($0 ~ "rows.push\\(\\{file: .*" fn ".*\\}\\);") {
          next
        }
      }
      print
    }
  ' "$INDEX" > "$tmp"

  mv "$tmp" "$INDEX"
  # Insert new row before END marker
  sed -i "/VIDRUN_MP4_ROWS_START/,/VIDRUN_MP4_ROWS_END/ {/VIDRUN_MP4_ROWS_END/i ${ROW_LINE}" "$INDEX"

  chown www-data:www-data "$INDEX" || true
fi
FALLBACK
  fi

  chmod +x "$target"

  # Optional: also keep a copy of the downloaded script in /opt/vidrun for the fallback to call
  mkdir -p /opt/vidrun
  if curl -fsSL "$REPO_SCROLLVID_URL" -o /opt/vidrun/scrollvid.sh; then
    chmod +x /opt/vidrun/scrollvid.sh
  fi
}

main() {
  require_root
  apt_setup
  prep_webroot
  nginx_config
  install_scrollvid

  echo
  echo "=== Done ==="
  echo "Web root:   $WEBROOT"
  echo "Nginx site: /etc/nginx/sites-available/${NGINX_SITE_NAME}"
  echo "Script:     /usr/local/bin/scrollvid.sh"
  echo
  echo "Tip: If you want the MP4 to land in the web folder, either:"
  echo "  - pass an ABSOLUTE path:  /var/www/html/public_html/mlb.mp4"
  echo "  - or just a filename (fallback wrapper will place it there):  mlb.mp4"
  echo
  echo "Test Nginx:  curl -I http://127.0.0.1/ | head -n1"
  echo "Test script: scrollvid.sh --help || true"
}

main "$@"
