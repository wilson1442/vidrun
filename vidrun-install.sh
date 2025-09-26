#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# VidRun / ScrollVid Installer (Ubuntu 24.04 / Proxmox)
# Installs:
#  - ffmpeg + fonts + helpers
#  - nginx (serves /var/www/html/public_html)
#  - pup (CSS selector HTML parser)
#  - scrollvid.sh, html2list.sh, vudrun.sh
#  - logrotate + cron (15 min schedule)
# ============================================================

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo bash vidrun-install.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "[1/7] Updating apt & installing dependencies..."
apt-get update -y
apt-get install -y --no-install-recommends \
  ffmpeg curl jq ca-certificates unzip \
  fonts-dejavu-core fonts-dejavu-extra fontconfig \
  lynx html-xml-utils nginx

echo "[2/7] Configuring nginx..."
mkdir -p /var/www/html/public_html
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html
systemctl enable nginx
systemctl restart nginx

echo "[3/7] Installing pup (CSS selector parser)..."
curl -fsSL https://github.com/ericchiang/pup/releases/download/v0.4.0/pup_v0.4.0_linux_amd64.zip -o /tmp/pup.zip
unzip -o /tmp/pup.zip -d /usr/local/bin
chmod +x /usr/local/bin/pup
rm /tmp/pup.zip

echo "[4/7] Creating directories..."
install -d -m 755 /opt/scrollvid/tmp
install -d -m 755 /var/log/scrollvid

echo "[5/7] Installing scrollvid.sh ..."
# (same as fixed version with safe filtergraph)
cat >/usr/local/bin/scrollvid.sh <<'EOSV'
[... full scrollvid.sh content from previous fixed version ...]
EOSV
chmod +x /usr/local/bin/scrollvid.sh

echo "[6/7] Installing html2list.sh ..."
cat >/usr/local/bin/html2list.sh <<'EOH2L'
[... html2list.sh content from previous version ...]
EOH2L
chmod +x /usr/local/bin/html2list.sh

echo "[7/7] Installing vudrun.sh, logrotate, cron ..."
cat >/root/vudrun.sh <<'EORUN'
[... vudrun.sh content with MLB example ...]
EORUN
chmod +x /root/vudrun.sh

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

cat >/etc/cron.d/scrollvid <<'EOCRON'
*/15 * * * * root /bin/bash -lc '/root/vudrun.sh >> /var/log/scrollvid/scheduler.log 2>&1'
EOCRON
chmod 644 /etc/cron.d/scrollvid

echo
echo "============================================================"
echo "✅ Install complete."
echo "Nginx root: /var/www/html/public_html"
echo "Generator:  /usr/local/bin/scrollvid.sh"
echo "Scraper:    /usr/local/bin/html2list.sh"
echo "Runner:     /root/vudrun.sh"
echo "Logs:       /var/log/scrollvid/"
echo "Cron:       /etc/cron.d/scrollvid"
echo
echo "Browse videos at: http://<server-ip>/public_html/"
echo "============================================================"
