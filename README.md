# vidrun
VidRun – Scrolling Text → MP4 (self-contained)

VidRun generates looping scrolling text videos (vertical by default) from a remote text file.
It installs a tiny web page that lists your generated MP4s with Copy and Delete buttons.

✅ Self-contained FFmpeg generator (/usr/local/bin/scrollvid.sh)

✅ Vertical scroll by default (horizontal optional)

✅ Left margin (tunable)

✅ Change detection (skips render if source text unchanged)

✅ Nginx site serves /var/www/html/public_html with proper MIME types

✅ Index page auto-updates rows on --html

✅ Delete button (HTTP DELETE via Nginx; only for *.mp4)

Latest working baseline: scrollvid 1.7

What it does:

Installs ffmpeg, nginx, fonts (DejaVu), curl, etc.

Creates /var/www/html/public_html and an index.html with table + buttons

Configures Nginx to include full MIME types and enable DELETE on *.mp4

Installs scrollvid 1.7 at /usr/local/bin/scrollvid.sh (verbose by default)

How it Works
Directory layout

Web root: /var/www/html/public_html

Index page: /var/www/html/public_html/index.html

Generator: /usr/local/bin/scrollvid.sh (v1.7)

Change detection cache: /opt/vidrun/state/<basename>.sha256
(SHA-256 of last processed text per output filename)

Common flags
Flag	Default	Description
`--direction vertical	horizontal`	vertical
--left-margin N	24	Left margin (px) for vertical mode.

--bg '#000000'	#000000	Background color.

--fg '#FFFF00'	#FFFFFF	Text color.

--stroke-color '#000000'	#000000	Text stroke (border) color.

--stroke-width N	0	Stroke width (px).

--font /path.ttf	DejaVu Sans	Font file.

--font-size N	52	Font size (px).

--speed N	140	Scroll speed (pixels/sec).

--width N	1920	Video width.

--height N	1080	Video height.

--duration N	60	Duration (seconds).

--audio /path.mp3	(none)	Optional background audio; loops/shortens to match video.

--audio-volume X	1.0	Audio gain (e.g., 0.8 for 80%).

--html	(off)	Update index.html table with row for the MP4.

--quiet	(verbose)	Suppress FFmpeg logs.

--debug	(off)	Shell trace; prints the exact commands run.
