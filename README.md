# vidrun
VIDRUN

Files & paths:
  • /usr/local/bin/scrollvid.sh     (video generator)
  • /root/vudrun.sh                 (multi-job runner — edit me)
  • /var/log/scrollvid/             (logs; auto-rotated)
  • /etc/cron.d/scrollvid           (runs every 15 minutes)

Quick test (one-off):
  scrollvid.sh "https://myboxconfig.com/fixtures/MLB.txt" mlb_test.mp4 \
    --bg '#000000' --fg '#FFFF00' --stroke-color '#000000' --stroke-width 3 \
    --audio /var/www/html/public_html/audio.mp3 --audio-volume 0.8
