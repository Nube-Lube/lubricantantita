"""
WiFi Music Server  —  YouTube download + offline PWA
-----------------------------------------------------
Run:    python server.py
Open:   http://<your-local-ip>:5000  on any phone/browser
"""

import os, sys, json, mimetypes, re
from flask import (Flask, Response, jsonify, request,
                   send_file, render_template_string, stream_with_context)

try:
    import requests as req_lib
    HAS_REQUESTS = True
except ImportError:
    HAS_REQUESTS = False

try:
    import yt_dlp
    HAS_YTDLP = True
except ImportError:
    HAS_YTDLP = False

# ── Paths ──────────────────────────────────────────────────────────────────
if getattr(sys, "frozen", False):
    BASE_DIR = os.path.dirname(os.path.dirname(sys.executable))
else:
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))

SONGS_DIR = os.path.join(BASE_DIR, "songs")
os.makedirs(SONGS_DIR, exist_ok=True)

AUDIO_EXTS = (".mp3", ".wav", ".flac", ".ogg", ".m4a", ".aac", ".webm", ".opus")

# ── Library ────────────────────────────────────────────────────────────────
albums: dict = {}
all_songs: list = []

def scan_library():
    global albums, all_songs
    albums, all_songs = {}, []
    for entry in sorted(os.listdir(SONGS_DIR)):
        ep = os.path.join(SONGS_DIR, entry)
        if os.path.isdir(ep):
            tracks = sorted(os.path.join(ep, f) for f in os.listdir(ep)
                            if f.lower().endswith(AUDIO_EXTS))
            if tracks:
                albums[entry] = tracks
                all_songs.extend(tracks)
        elif entry.lower().endswith(AUDIO_EXTS):
            albums.setdefault("_root", []).append(ep)
            all_songs.append(ep)

scan_library()
print(f"\n🎵  {len(all_songs)} tracks  |  {len(albums)} album(s)")

def rel(path):    return os.path.relpath(path, SONGS_DIR)
def absp(rp):     return os.path.normpath(os.path.join(SONGS_DIR, rp))
def sanitize(n):  return re.sub(r'[\\/:*?"<>|]', "_", n).strip()

def find_downloaded(title_safe, folder=None):
    """Return the relative path of a just-downloaded file, or ''."""
    search_dir = os.path.join(SONGS_DIR, sanitize(folder)) if folder else SONGS_DIR
    for ext in AUDIO_EXTS:
        candidate = os.path.join(search_dir, f"{title_safe}{ext}")
        if os.path.exists(candidate):
            return rel(candidate).replace(os.sep, '/')
    return ""

# ── yt-dlp downloader ─────────────────────────────────────────────────────
def ytdlp_download(video_url: str, title: str, folder):
    """Download one video via yt-dlp and save to songs/ as m4a."""
    if not HAS_YTDLP:
        raise RuntimeError("Run: pip install yt-dlp")

    safe = sanitize(title)
    if folder:
        out_dir = os.path.join(SONGS_DIR, sanitize(folder))
        os.makedirs(out_dir, exist_ok=True)
        outtmpl = os.path.join(out_dir, f"{safe}.%(ext)s")
    else:
        outtmpl = os.path.join(SONGS_DIR, f"{safe}.%(ext)s")

    # Skip if already downloaded
    for ext in AUDIO_EXTS:
        candidate = outtmpl.replace(".%(ext)s", ext)
        if os.path.exists(candidate):
            return

    ydl_opts = {
        "format": "bestaudio[ext=m4a]/bestaudio",
        "postprocessors": [{
            "key": "FFmpegExtractAudio",
            "preferredcodec": "m4a",
            "preferredquality": "0",
        }],
        "outtmpl": outtmpl,
        "nooverwrites": True,
        "quiet": True,
        "no_warnings": True,
    }

    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([video_url])
        return
    except Exception:
        pass

    # Fallback: no postprocessor
    ydl_opts_raw = {
        "format": "bestaudio[ext=m4a]/bestaudio",
        "outtmpl": outtmpl,
        "nooverwrites": True,
        "quiet": True,
        "no_warnings": True,
    }
    with yt_dlp.YoutubeDL(ydl_opts_raw) as ydl:
        ydl.download([video_url])

def get_title(url):
    if HAS_YTDLP:
        try:
            with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True}) as y:
                return y.extract_info(url, download=False).get("title", "Track")
        except Exception:
            pass
    return "YouTube Track"

# ── Service Worker ─────────────────────────────────────────────────────────
SW_JS = """
const SHELL = 'wireless-shell-v2';
const SHELL_URLS = ['/', '/manifest.json'];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(SHELL_URLS)));
  self.skipWaiting();
});
self.addEventListener('activate', e => e.waitUntil(clients.claim()));
self.addEventListener('fetch', e => {
  const url = e.request.url;
  if (url.includes('/stream/') || url.includes('/api/')) return;
  e.respondWith(
    fetch(e.request)
      .then(r => { const clone = r.clone(); caches.open(SHELL).then(c => c.put(e.request, clone)); return r; })
      .catch(() => caches.match(e.request))
  );
});
"""

# ── HTML ───────────────────────────────────────────────────────────────────
HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"/>
<meta name="apple-mobile-web-app-capable" content="yes"/>
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent"/>
<meta name="theme-color" content="#0c0c0e"/>
<title>Wireless</title>
<link rel="manifest" href="/manifest.json"/>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display:ital@0;1&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
  :root {
    --bg:#0c0c0e; --surface:#18181c; --elevated:#232329;
    --border:rgba(255,255,255,0.07); --accent:#e8c96e; --accent2:#c46f3c;
    --text:#f0ede6; --muted:#7c7970; --radius:16px;
  }
  *,*::before,*::after{box-sizing:border-box;margin:0;padding:0;}
  html,body{height:100%;background:var(--bg);color:var(--text);font-family:'DM Mono',monospace;
    font-size:14px;overscroll-behavior:none;-webkit-font-smoothing:antialiased;}
  #offline-banner{display:none;position:fixed;top:env(safe-area-inset-top,0);left:0;right:0;
    background:#c46f3c;color:#fff;text-align:center;padding:6px;font-size:12px;
    letter-spacing:.06em;z-index:200;}
  body.offline #offline-banner{display:block;}
  #app{display:grid;grid-template-rows:1fr auto;height:100dvh;max-width:540px;margin:0 auto;
    padding:env(safe-area-inset-top,12px) 0 env(safe-area-inset-bottom,0);}
  #tabs{display:flex;background:var(--surface);border-top:1px solid var(--border);
    padding-bottom:env(safe-area-inset-bottom,0);}
  .tab-btn{flex:1;border:none;background:transparent;color:var(--muted);padding:12px 0 10px;
    font-family:'DM Mono',monospace;font-size:10px;letter-spacing:.05em;text-transform:uppercase;
    cursor:pointer;transition:color .2s;display:flex;flex-direction:column;align-items:center;gap:3px;
    -webkit-tap-highlight-color:transparent;}
  .tab-btn svg{width:20px;height:20px;stroke:currentColor;fill:none;stroke-width:1.5;}
  .tab-btn.active{color:var(--accent);}
  .panel{display:none;flex-direction:column;overflow:hidden;height:100%;}
  .panel.active{display:flex;}
  #panel-now{align-items:center;justify-content:flex-end;padding:24px 28px 20px;gap:0;
    background:radial-gradient(ellipse 80% 50% at 50% 0%,rgba(232,201,110,.12) 0%,transparent 70%),var(--bg);}
  #album-art{width:min(240px,65vw);height:min(240px,65vw);border-radius:24px;background:var(--elevated);
    display:flex;align-items:center;justify-content:center;margin-bottom:28px;margin-top:auto;
    box-shadow:0 24px 64px rgba(0,0,0,.6),0 0 0 1px var(--border);overflow:hidden;flex-shrink:0;}
  #album-art.playing{animation:float 4s ease-in-out infinite;}
  @keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-6px)}}
  #album-art svg{width:64px;height:64px;stroke:var(--muted);fill:none;stroke-width:1;}
  #track-info{width:100%;text-align:center;margin-bottom:20px;}
  #track-title{font-family:'DM Serif Display',serif;font-size:20px;line-height:1.2;color:var(--text);
    margin-bottom:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  #track-album{color:var(--muted);font-size:12px;letter-spacing:.06em;text-transform:uppercase;}
  #progress-wrap{width:100%;margin-bottom:14px;}
  #progress-bar{width:100%;height:3px;background:var(--elevated);border-radius:99px;cursor:pointer;
    -webkit-appearance:none;appearance:none;border:none;outline:none;}
  #progress-bar::-webkit-slider-thumb{-webkit-appearance:none;width:14px;height:14px;border-radius:50%;
    background:var(--accent);cursor:pointer;box-shadow:0 0 8px rgba(232,201,110,.5);}
  #progress-bar::-moz-range-thumb{width:14px;height:14px;border-radius:50%;background:var(--accent);cursor:pointer;border:none;}
  input[type=range]{accent-color:var(--accent);}
  #time-row{display:flex;justify-content:space-between;margin-top:6px;color:var(--muted);font-size:11px;}
  #controls{display:flex;align-items:center;justify-content:center;gap:24px;width:100%;margin-bottom:18px;}
  .ctrl-btn{border:none;background:transparent;cursor:pointer;padding:8px;color:var(--muted);
    border-radius:50%;transition:color .15s,transform .1s;-webkit-tap-highlight-color:transparent;}
  .ctrl-btn:active{transform:scale(.88);}
  .ctrl-btn svg{width:26px;height:26px;stroke:currentColor;fill:none;stroke-width:1.5;display:block;}
  #btn-play{width:60px;height:60px;border-radius:50%;background:var(--accent);color:var(--bg);
    box-shadow:0 0 32px rgba(232,201,110,.35);}
  #btn-play svg{width:26px;height:26px;}
  .ctrl-btn.active{color:var(--accent);}
  #vol-wrap{display:flex;align-items:center;gap:10px;width:100%;margin-bottom:4px;}
  #vol-wrap svg{width:18px;height:18px;stroke:var(--muted);fill:none;stroke-width:1.5;flex-shrink:0;}
  #vol-slider{flex:1;height:3px;-webkit-appearance:none;appearance:none;background:var(--elevated);
    border-radius:99px;border:none;outline:none;cursor:pointer;}
  #vol-slider::-webkit-slider-thumb{-webkit-appearance:none;width:14px;height:14px;border-radius:50%;background:var(--text);cursor:pointer;}
  .panel-header{padding:18px 20px 12px;border-bottom:1px solid var(--border);flex-shrink:0;
    display:flex;align-items:center;justify-content:space-between;}
  .panel-header h2{font-family:'DM Serif Display',serif;font-size:22px;font-weight:400;}
  .panel-actions{display:flex;gap:8px;}
  .pill-btn{border:1px solid var(--border);background:var(--elevated);color:var(--text);
    padding:6px 14px;border-radius:99px;font-family:'DM Mono',monospace;font-size:11px;
    letter-spacing:.05em;cursor:pointer;white-space:nowrap;transition:background .15s;
    -webkit-tap-highlight-color:transparent;}
  .pill-btn:active{background:var(--accent);border-color:var(--accent);color:var(--bg);}
  #panel-library{overflow:hidden;}
  #library-scroll{overflow-y:auto;flex:1;-webkit-overflow-scrolling:touch;padding:8px 0 16px;}
  .album-section{margin-bottom:2px;}
  .album-header{display:flex;align-items:center;justify-content:space-between;padding:12px 20px;
    cursor:pointer;-webkit-tap-highlight-color:transparent;border-radius:var(--radius);transition:background .12s;}
  .album-header:active{background:var(--elevated);}
  .album-name{font-family:'DM Serif Display',serif;font-size:16px;font-weight:400;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:60%;}
  .album-right{display:flex;align-items:center;gap:8px;flex-shrink:0;}
  .album-meta{color:var(--muted);font-size:11px;letter-spacing:.04em;}
  .album-dl{border:none;background:transparent;color:var(--muted);cursor:pointer;padding:4px;
    -webkit-tap-highlight-color:transparent;display:flex;align-items:center;transition:color .15s;}
  .album-dl:active{color:var(--accent);}
  .album-dl svg{width:15px;height:15px;stroke:currentColor;fill:none;stroke-width:1.5;}
  .album-tracks{padding:0 0 4px;}
  .album-tracks.hidden{display:none;}
  .track-row{display:flex;align-items:center;gap:10px;padding:9px 20px;cursor:pointer;
    -webkit-tap-highlight-color:transparent;transition:background .12s;}
  .track-row:active{background:var(--elevated);}
  .track-num{color:var(--muted);font-size:12px;width:20px;text-align:right;flex-shrink:0;}
  .track-name{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .track-row.playing .track-name,.track-row.playing .track-num{color:var(--accent);}
  .track-add{border:none;background:transparent;color:var(--muted);cursor:pointer;padding:4px;
    font-size:17px;line-height:1;flex-shrink:0;-webkit-tap-highlight-color:transparent;transition:color .15s,transform .1s;}
  .track-add:active{transform:scale(.8);color:var(--accent);}
  .track-cache{border:none;background:transparent;color:var(--muted);cursor:pointer;padding:4px;
    flex-shrink:0;-webkit-tap-highlight-color:transparent;transition:color .15s,transform .1s;display:flex;align-items:center;}
  .track-cache svg{width:15px;height:15px;stroke:currentColor;fill:none;stroke-width:1.5;}
  .track-cache:active{transform:scale(.8);}
  .track-cache.cached{color:var(--accent);}
  .track-cache.caching{color:var(--muted);animation:pulse 1s ease-in-out infinite;}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
  #panel-queue{overflow:hidden;}
  #queue-scroll{overflow-y:auto;flex:1;-webkit-overflow-scrolling:touch;padding:8px 0 16px;}
  .queue-item{display:flex;align-items:center;gap:12px;padding:11px 20px;}
  .queue-item-name{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}
  .queue-item-album{color:var(--muted);font-size:11px;}
  .queue-remove{border:none;background:transparent;color:var(--muted);cursor:pointer;padding:4px;
    font-size:18px;flex-shrink:0;-webkit-tap-highlight-color:transparent;transition:color .15s;}
  .queue-remove:active{color:#e05555;}
  .empty-state{text-align:center;color:var(--muted);padding:48px 24px;line-height:1.8;}
  .empty-state span{font-family:'DM Serif Display',serif;font-size:20px;display:block;margin-bottom:8px;color:var(--text);}
  #panel-youtube{overflow:hidden;}
  .yt-input-row{display:flex;gap:8px;padding:14px 20px 12px;border-bottom:1px solid var(--border);flex-shrink:0;}
  #yt-url{flex:1;background:var(--elevated);border:1px solid var(--border);border-radius:12px;
    color:var(--text);font-family:'DM Mono',monospace;font-size:13px;padding:10px 14px;
    outline:none;transition:border-color .2s;}
  #yt-url:focus{border-color:var(--accent);}
  #yt-url::placeholder{color:var(--muted);}
  #yt-go{background:var(--accent);color:var(--bg);border:none;border-radius:12px;padding:10px 16px;
    font-family:'DM Mono',monospace;font-size:13px;cursor:pointer;font-weight:500;white-space:nowrap;
    transition:background .15s;-webkit-tap-highlight-color:transparent;}
  #yt-go:disabled{background:var(--elevated);color:var(--muted);cursor:default;}
  .yt-notice{margin:10px 20px 0;padding:10px 14px;background:var(--elevated);border-radius:10px;
    font-size:12px;color:var(--muted);line-height:1.6;flex-shrink:0;}
  .yt-notice b,.yt-notice code{color:var(--text);}
  #storage-wrap{padding:10px 20px 8px;flex-shrink:0;}
  #storage-label{color:var(--muted);font-size:11px;margin-bottom:5px;display:flex;justify-content:space-between;}
  #storage-bar{height:2px;background:var(--elevated);border-radius:99px;overflow:hidden;}
  #storage-fill{height:100%;background:var(--accent);border-radius:99px;transition:width .5s;width:0%;}
  #yt-scroll{overflow-y:auto;flex:1;-webkit-overflow-scrolling:touch;padding:4px 0 16px;}
  .dl-item{display:flex;align-items:center;gap:12px;padding:11px 20px;}
  .dl-icon{width:30px;height:30px;border-radius:8px;background:var(--elevated);
    display:flex;align-items:center;justify-content:center;flex-shrink:0;}
  .dl-icon svg{width:14px;height:14px;stroke:currentColor;fill:none;stroke-width:2;}
  .dl-icon.pending{color:var(--muted);}
  .dl-icon.active{color:var(--accent);animation:pulse 1s ease-in-out infinite;}
  .dl-icon.done{color:#6ec47a;}
  .dl-icon.error{color:#e05555;}
  .dl-info{flex:1;min-width:0;}
  .dl-title{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:13px;}
  .dl-sub{color:var(--muted);font-size:11px;margin-top:2px;}
  #toast{position:fixed;bottom:90px;left:50%;transform:translateX(-50%) translateY(20px);
    background:var(--elevated);color:var(--text);border:1px solid var(--border);
    padding:10px 20px;border-radius:99px;font-size:13px;opacity:0;pointer-events:none;
    transition:opacity .25s,transform .25s;white-space:nowrap;z-index:99;}
  #toast.show{opacity:1;transform:translateX(-50%) translateY(0);}
  ::-webkit-scrollbar{width:4px;}
  ::-webkit-scrollbar-track{background:transparent;}
  ::-webkit-scrollbar-thumb{background:var(--elevated);border-radius:99px;}
</style>
</head>
<body>
<div id="offline-banner">Offline — playing cached tracks</div>
<div id="app">
  <div class="panel active" id="panel-now">
    <div id="album-art">
      <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="3"/><path d="M12 2a10 10 0 0 1 0 20"/></svg>
    </div>
    <div id="track-info">
      <div id="track-title">Nothing playing</div>
      <div id="track-album">—</div>
    </div>
    <div id="progress-wrap">
      <input id="progress-bar" type="range" min="0" max="100" value="0" step="0.1"/>
      <div id="time-row"><span id="t-current">0:00</span><span id="t-total">0:00</span></div>
    </div>
    <div id="controls">
      <button class="ctrl-btn" id="btn-shuffle"><svg viewBox="0 0 24 24"><path d="M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5"/></svg></button>
      <button class="ctrl-btn" id="btn-prev"><svg viewBox="0 0 24 24"><path d="M19 20 9 12l10-8v16zM5 19V5"/></svg></button>
      <button class="ctrl-btn" id="btn-play">
        <svg id="icon-play"  viewBox="0 0 24 24"><polygon points="5 3 19 12 5 21 5 3"/></svg>
        <svg id="icon-pause" viewBox="0 0 24 24" style="display:none"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg>
      </button>
      <button class="ctrl-btn" id="btn-next"><svg viewBox="0 0 24 24"><path d="M5 4l10 8-10 8V4zM19 5v14"/></svg></button>
      <button class="ctrl-btn" id="btn-repeat"><svg viewBox="0 0 24 24"><polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14M7 23l-4-4 4-4"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg></button>
    </div>
    <div id="vol-wrap">
      <svg viewBox="0 0 24 24"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/></svg>
      <input id="vol-slider" type="range" min="0" max="1" step="0.01" value="1"/>
      <svg viewBox="0 0 24 24"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07M19.07 4.93a10 10 0 0 1 0 14.14"/></svg>
    </div>
  </div>
  <div class="panel" id="panel-library">
    <div class="panel-header">
      <h2>Library</h2>
      <div class="panel-actions"><button class="pill-btn" id="btn-shuffle-all">Shuffle All</button></div>
    </div>
    <div id="library-scroll"></div>
  </div>
  <div class="panel" id="panel-queue">
    <div class="panel-header">
      <h2>Queue</h2>
      <div class="panel-actions"><button class="pill-btn" id="btn-clear-queue">Clear</button></div>
    </div>
    <div id="queue-scroll"></div>
  </div>
  <div class="panel" id="panel-youtube">
    <div class="panel-header" style="border-bottom:none;padding-bottom:0;">
      <h2>YouTube</h2>
    </div>
    <div class="yt-input-row">
      <input id="yt-url" type="url" placeholder="Paste YouTube video or playlist URL…" autocomplete="off" autocorrect="off" spellcheck="false"/>
      <button id="yt-go">Download</button>
    </div>
    <div id="yt-notice-wrap"></div>
    <div id="storage-wrap">
      <div id="storage-label"><span>Offline storage</span><span id="storage-size">—</span></div>
      <div id="storage-bar"><div id="storage-fill"></div></div>
    </div>
    <div id="yt-scroll">
      <div class="empty-state"><span>No downloads yet</span>Paste a YouTube URL above</div>
    </div>
  </div>
  <div id="tabs">
    <button class="tab-btn active" data-panel="panel-now">
      <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="3"/></svg>Now
    </button>
    <button class="tab-btn" data-panel="panel-library">
      <svg viewBox="0 0 24 24"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>Library
    </button>
    <button class="tab-btn" data-panel="panel-queue">
      <svg viewBox="0 0 24 24"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg>Queue
    </button>
    <button class="tab-btn" data-panel="panel-youtube">
      <svg viewBox="0 0 24 24"><path d="M22.54 6.42a2.78 2.78 0 0 0-1.95-1.96C18.88 4 12 4 12 4s-6.88 0-8.59.46A2.78 2.78 0 0 0 1.46 6.42 29 29 0 0 0 1 12a29 29 0 0 0 .46 5.58 2.78 2.78 0 0 0 1.95 1.96C5.12 20 12 20 12 20s6.88 0 8.59-.46a2.78 2.78 0 0 0 1.95-1.96A29 29 0 0 0 23 12a29 29 0 0 0-.46-5.58z"/><polygon points="9.75 15.02 15.5 12 9.75 8.98 9.75 15.02"/></svg>YouTube
    </button>
  </div>
</div>
<div id="toast"></div>
<audio id="audio" preload="none"></audio>
<script>
const CFG = window.SERVER_CONFIG || {hasRequests:false,hasYtdlp:false};
const audio = document.getElementById('audio');
let queue=[], history=[], current=null, shuffle=false, repeatOne=false, library={};

function openDB() {
  return new Promise((res,rej) => {
    const r = indexedDB.open('wireless-audio',1);
    r.onupgradeneeded = e => e.target.result.createObjectStore('tracks');
    r.onsuccess = e => res(e.target.result);
    r.onerror   = e => rej(e.target.error);
  });
}
async function dbGet(k)   { const db=await openDB(); return new Promise(res=>{const r=db.transaction('tracks','readonly').objectStore('tracks').get(k);r.onsuccess=()=>res(r.result||null);r.onerror=()=>res(null);}); }
async function dbSet(k,v) { const db=await openDB(); return new Promise((res,rej)=>{const tx=db.transaction('tracks','readwrite');tx.objectStore('tracks').put(v,k);tx.oncomplete=res;tx.onerror=rej;}); }
async function dbDel(k)   { const db=await openDB(); return new Promise((res,rej)=>{const tx=db.transaction('tracks','readwrite');tx.objectStore('tracks').delete(k);tx.oncomplete=res;tx.onerror=rej;}); }
async function dbKeys()   { const db=await openDB(); return new Promise(res=>{const r=db.transaction('tracks','readonly').objectStore('tracks').getAllKeys();r.onsuccess=()=>res(r.result);r.onerror=()=>res([]);}); }

let cachedKeys = new Set();
const cacheKey = rel => '/stream/' + encodeURIComponent(rel);
const SVG_DL    = '<svg viewBox="0 0 24 24"><path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>';
const SVG_CHECK = '<svg viewBox="0 0 24 24"><path d="M20 6L9 17l-5-5"/></svg>';
const SVG_SPIN  = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" stroke-dasharray="20 40" stroke-linecap="round"/></svg>';

function setCacheIcon(el, state) {
  if (!el) return;
  el.classList.remove('cached','caching');
  if (state==='cached')   {el.innerHTML=SVG_CHECK;el.classList.add('cached');el.title='Saved offline — tap to remove';}
  else if (state==='caching'){el.innerHTML=SVG_SPIN;el.classList.add('caching');el.title='Saving…';}
  else                    {el.innerHTML=SVG_DL;el.title='Save for offline playback';}
}
function refreshCacheIcons() {
  document.querySelectorAll('.track-cache').forEach(el => {
    const row = el.closest('.track-row');
    if (row) setCacheIcon(el, cachedKeys.has(cacheKey(row.dataset.rel)) ? 'cached' : 'uncached');
  });
}
async function updateStorageBar() {
  if (!navigator.storage || !navigator.storage.estimate) return;
  const {usage=0, quota=1} = await navigator.storage.estimate();
  const pct = Math.min(100, (usage/quota)*100).toFixed(1);
  document.getElementById('storage-fill').style.width = pct+'%';
  document.getElementById('storage-size').textContent = (usage/1048576).toFixed(0)+' MB';
}
async function toggleCache(track, iconEl) {
  const key = cacheKey(track.rel);
  if (cachedKeys.has(key)) {
    await dbDel(key); cachedKeys.delete(key);
    setCacheIcon(iconEl,'uncached'); toast('Removed from offline storage');
    updateStorageBar(); return;
  }
  setCacheIcon(iconEl,'caching');
  try {
    const resp = await fetch('/stream/'+encodeURIComponent(track.rel));
    if (!resp.ok) throw new Error(resp.status);
    const blob = await resp.blob();
    await dbSet(key, blob); cachedKeys.add(key);
    setCacheIcon(iconEl,'cached'); toast('Saved: '+track.name);
    updateStorageBar();
  } catch {
    setCacheIcon(iconEl,'uncached'); toast('Save failed — check your connection');
  }
}
async function cacheAlbum(tracks, name) {
  toast('Saving album…');
  for (const t of tracks) {
    const key = cacheKey(t.rel);
    if (cachedKeys.has(key)) continue;
    try {
      const blob = await fetch('/stream/'+encodeURIComponent(t.rel)).then(r=>r.blob());
      await dbSet(key,blob); cachedKeys.add(key);
    } catch {}
  }
  refreshCacheIcons(); updateStorageBar(); toast('"'+name+'" saved offline');
}

async function init() {
  try {
    library = await fetch('/api/library').then(r=>r.json());
    localStorage.setItem('wireless-lib', JSON.stringify(library));
  } catch {
    const c = localStorage.getItem('wireless-lib');
    if (c) { library=JSON.parse(c); toast('Offline — showing cached library'); }
  }
  renderLibrary();
  cachedKeys = new Set(await dbKeys());
  refreshCacheIcons();
  updateStorageBar();
  window.addEventListener('online',  () => document.body.classList.remove('offline'));
  window.addEventListener('offline', () => document.body.classList.add('offline'));
  if (!navigator.onLine) document.body.classList.add('offline');
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(()=>{});
  if (navigator.storage && navigator.storage.persist) navigator.storage.persist();
  const nw = document.getElementById('yt-notice-wrap');
  if (!CFG.hasYtdlp)
    nw.innerHTML = '<div class="yt-notice">For downloads: <code>pip install yt-dlp</code> and restart.</div>';
}

let _tt;
function toast(msg) {
  const el=document.getElementById('toast');
  el.textContent=msg; el.classList.add('show');
  clearTimeout(_tt); _tt=setTimeout(()=>el.classList.remove('show'),2500);
}

document.querySelectorAll('.tab-btn').forEach(b=>b.addEventListener('click',()=>switchTab(b.dataset.panel)));
function switchTab(id) {
  document.querySelectorAll('.tab-btn,.panel').forEach(el=>el.classList.remove('active'));
  document.querySelector('[data-panel="'+id+'"]').classList.add('active');
  document.getElementById(id).classList.add('active');
}

function renderLibrary() {
  const scroll = document.getElementById('library-scroll');
  scroll.innerHTML = '';
  for (const [album, tracks] of Object.entries(library)) {
    const dn = album==='_root' ? 'Songs' : album;
    const sec = document.createElement('div'); sec.className='album-section';
    const hdr = document.createElement('div'); hdr.className='album-header';
    hdr.innerHTML =
      '<span class="album-name">'+dn+'</span>'+
      '<span class="album-right">'+
        '<span class="album-meta">'+tracks.length+' track'+(tracks.length!==1?'s':'')+'</span>'+
        '<button class="album-dl" title="Save whole album offline">'+
          '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M4 16v1a3 3 0 003 3h10a3 3 0 003-3v-1m-4-4l-4 4m0 0l-4-4m4 4V4"/></svg>'+
        '</button>'+
      '</span>';
    hdr.querySelector('.album-dl').addEventListener('click', e => { e.stopPropagation(); cacheAlbum(tracks, dn); });
    const tl = document.createElement('div'); tl.className='album-tracks hidden';
    tracks.forEach((t,i) => {
      const row = document.createElement('div'); row.className='track-row'; row.dataset.rel=t.rel;
      row.innerHTML =
        '<span class="track-num">'+(i+1)+'</span>'+
        '<span class="track-name">'+t.name+'</span>'+
        '<button class="track-cache">'+SVG_DL+'</button>'+
        '<button class="track-add" title="Add to queue">+</button>';
      const cBtn = row.querySelector('.track-cache');
      if (cachedKeys.has(cacheKey(t.rel))) setCacheIcon(cBtn,'cached');
      row.querySelector('.track-name').addEventListener('click', ()=>{ queue.unshift({...t,album}); playNext(); switchTab('panel-now'); });
      cBtn.addEventListener('click', e=>{ e.stopPropagation(); toggleCache(t,cBtn); });
      row.querySelector('.track-add').addEventListener('click', e=>{ e.stopPropagation(); queue.push({...t,album}); toast('Added: '+t.name); renderQueue(); });
      tl.appendChild(row);
    });
    let tapT=0;
    hdr.addEventListener('click', e => {
      if (e.target.closest('.album-dl')) return;
      const now=Date.now();
      if (now-tapT<350) { queue.push(...tracks.map(t=>({...t,album}))); renderQueue(); toast('Queued: '+dn); }
      else tl.classList.toggle('hidden');
      tapT=now;
    });
    sec.appendChild(hdr); sec.appendChild(tl); scroll.appendChild(sec);
  }
}

async function refreshLibrary() {
  try {
    library = await fetch('/api/library').then(r=>r.json());
    localStorage.setItem('wireless-lib', JSON.stringify(library));
    renderLibrary(); toast('Library refreshed');
  } catch {}
}

function renderQueue() {
  const s=document.getElementById('queue-scroll');
  if (!queue.length) { s.innerHTML='<div class="empty-state"><span>Queue is empty</span>Add songs from the Library tab</div>'; return; }
  s.innerHTML='';
  queue.forEach((t,i)=>{
    const row=document.createElement('div'); row.className='queue-item';
    row.innerHTML='<div style="flex:1;min-width:0"><div class="queue-item-name">'+t.name+'</div><div class="queue-item-album">'+(t.album==='_root'?'':t.album)+'</div></div><button class="queue-remove">×</button>';
    row.querySelector('.queue-remove').addEventListener('click',()=>{queue.splice(i,1);renderQueue();});
    s.appendChild(row);
  });
}

let blobUrl=null;
async function playTrack(track) {
  current=track;
  if (blobUrl) { URL.revokeObjectURL(blobUrl); blobUrl=null; }
  const blob = await dbGet(cacheKey(track.rel));
  if (blob) { blobUrl=URL.createObjectURL(blob); audio.src=blobUrl; }
  else       audio.src='/stream/'+encodeURIComponent(track.rel);
  audio.load(); audio.play().catch(()=>{});
  document.getElementById('track-title').textContent=track.name;
  document.getElementById('track-album').textContent=track.album==='_root'?'':track.album;
  document.getElementById('album-art').classList.add('playing');
  document.querySelectorAll('.track-row').forEach(r=>r.classList.toggle('playing',r.dataset.rel===track.rel));
}
function playNext() {
  if (!queue.length) {
    audio.pause(); current=null;
    document.getElementById('track-title').textContent='Nothing playing';
    document.getElementById('track-album').textContent='—';
    document.getElementById('album-art').classList.remove('playing');
    return;
  }
  let t; if(shuffle){const i=Math.floor(Math.random()*queue.length);[t]=queue.splice(i,1);}else t=queue.shift();
  if(current) history.push(current);
  playTrack(t); renderQueue();
}
function playPrev() {
  if(history.length){ if(current)queue.unshift(current); playTrack(history.pop()); renderQueue(); }
  else audio.currentTime=0;
}
audio.addEventListener('play',  ()=>{document.getElementById('icon-play').style.display='none';document.getElementById('icon-pause').style.display='';});
audio.addEventListener('pause', ()=>{document.getElementById('icon-play').style.display='';document.getElementById('icon-pause').style.display='none';});
audio.addEventListener('ended', ()=>{ if(repeatOne)audio.play(); else playNext(); });
audio.addEventListener('timeupdate', ()=>{
  if(!audio.duration)return;
  document.getElementById('progress-bar').value=(audio.currentTime/audio.duration)*100;
  document.getElementById('t-current').textContent=fmt(audio.currentTime);
  document.getElementById('t-total').textContent=fmt(audio.duration);
});
function fmt(s){const m=Math.floor(s/60),sec=Math.floor(s%60);return m+':'+String(sec).padStart(2,'0');}
document.getElementById('btn-play').addEventListener('click',()=>{
  if(!current&&queue.length){playNext();return;}
  if(!current){toast('Nothing queued');return;}
  audio.paused?audio.play():audio.pause();
});
document.getElementById('btn-next').addEventListener('click',playNext);
document.getElementById('btn-prev').addEventListener('click',playPrev);
document.getElementById('btn-shuffle').addEventListener('click',()=>{shuffle=!shuffle;document.getElementById('btn-shuffle').classList.toggle('active',shuffle);toast(shuffle?'Shuffle on':'Shuffle off');});
document.getElementById('btn-repeat').addEventListener('click',()=>{repeatOne=!repeatOne;document.getElementById('btn-repeat').classList.toggle('active',repeatOne);toast(repeatOne?'Repeat on':'Repeat off');});
document.getElementById('progress-bar').addEventListener('input',e=>{if(audio.duration)audio.currentTime=(e.target.value/100)*audio.duration;});
document.getElementById('vol-slider').addEventListener('input',e=>{audio.volume=e.target.value;});
document.getElementById('btn-shuffle-all').addEventListener('click',()=>{
  const all=Object.entries(library).flatMap(([a,ts])=>ts.map(t=>({...t,album:a})));
  for(let i=all.length-1;i>0;i--){const j=Math.floor(Math.random()*(i+1));[all[i],all[j]]=[all[j],all[i]];}
  queue=all; renderQueue(); playNext(); switchTab('panel-now'); toast('Shuffling '+all.length+' tracks');
});
document.getElementById('btn-clear-queue').addEventListener('click',()=>{queue=[];renderQueue();toast('Queue cleared');});

const ytScroll=document.getElementById('yt-scroll');
const ytGo=document.getElementById('yt-go');
const ytInput=document.getElementById('yt-url');
let activeES=null, dlItems={};
ytGo.addEventListener('click', startDL);
ytInput.addEventListener('keydown', e=>{ if(e.key==='Enter') startDL(); });
function startDL() {
  const url=ytInput.value.trim();
  if(!url||!url.startsWith('http')){toast('Paste a valid YouTube URL');return;}
  if(!CFG.hasYtdlp){toast('Run: pip install yt-dlp');return;}
  if(activeES){activeES.close();activeES=null;}
  ytScroll.innerHTML=''; dlItems={};
  ytGo.disabled=true; ytGo.textContent='Downloading…';
  activeES=new EventSource('/api/youtube?url='+encodeURIComponent(url));
  activeES.onmessage=e=>{
    const d=JSON.parse(e.data);
    handleDLEvent(d);
    if(d.status==='complete'||(d.status==='error'&&!d.track)){
      activeES.close(); activeES=null;
      ytGo.disabled=false; ytGo.textContent='Download';
      refreshLibrary();
    }
  };
  activeES.onerror=()=>{
    if(activeES){activeES.close();activeES=null;}
    ytGo.disabled=false; ytGo.textContent='Download';
    toast('Connection error');
  };
}
function handleDLEvent(d) {
  if(d.status==='playlist'){ytScroll.innerHTML='';toast(d.name+' — '+d.total+' tracks');return;}
  if(d.status==='complete'){toast('All done!');return;}
  if(d.status==='error'&&!d.track){addDL('Error',d.error||'Unknown error','error');return;}
  if(d.track){
    const state=d.status==='done'?'done':d.status==='error'?'error':'active';
    const sub=d.status==='done'?'Saved':d.status==='error'?(d.error||'Failed'):(d.index&&d.total?d.index+' / '+d.total:'Downloading…');
    if(dlItems[d.track]) updateDL(dlItems[d.track],state,sub);
    else dlItems[d.track]=addDL(d.track,sub,state);
  }
}
function dlSVG(state){
  if(state==='done')  return '<svg viewBox="0 0 24 24"><path d="M20 6L9 17l-5-5"/></svg>';
  if(state==='error') return '<svg viewBox="0 0 24 24"><path d="M18 6L6 18M6 6l12 12"/></svg>';
  if(state==='active')return '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" stroke-dasharray="20 40" stroke-linecap="round"/></svg>';
  return '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/></svg>';
}
function addDL(title,sub,state){
  const el=document.createElement('div'); el.className='dl-item';
  el.innerHTML='<div class="dl-icon '+state+'">'+dlSVG(state)+'</div><div class="dl-info"><div class="dl-title">'+title+'</div><div class="dl-sub">'+sub+'</div></div>';
  ytScroll.appendChild(el); el.scrollIntoView({behavior:'smooth',block:'end'}); return el;
}
function updateDL(el,state,sub){
  el.querySelector('.dl-icon').className='dl-icon '+state;
  el.querySelector('.dl-icon').innerHTML=dlSVG(state);
  el.querySelector('.dl-sub').textContent=sub;
}
init();
</script>
</body>
</html>"""

# ── Flask ──────────────────────────────────────────────────────────────────
app = Flask(__name__)

@app.route("/")
def index():
    cfg = json.dumps({"hasRequests": HAS_REQUESTS, "hasYtdlp": HAS_YTDLP, "isServer": True})
    page = HTML.replace("</head>", f"<script>window.SERVER_CONFIG={cfg};</script></head>", 1)
    return Response(page, mimetype="text/html")

@app.route("/sw.js")
def sw():
    return Response(SW_JS, mimetype="application/javascript",
                    headers={"Service-Worker-Allowed": "/"})

@app.after_request
def add_cors(resp):
    resp.headers["Access-Control-Allow-Origin"]  = "*"
    resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    resp.headers["Access-Control-Allow-Headers"] = "Content-Type"
    return resp

@app.route("/api/ping")
def api_ping():
    return jsonify({
        "name":    "Wireless Music Server",
        "tracks":  len(all_songs),
        "albums":  len(albums),
        "ytdlp":   HAS_YTDLP,
        "version": 2,
    })

@app.route("/manifest.json")
def manifest():
    return jsonify({
        "name": "Wireless", "short_name": "Wireless",
        "start_url": "/", "display": "standalone",
        "background_color": "#0c0c0e", "theme_color": "#0c0c0e",
        "icons": [{"src": "data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' rx='20' fill='%230c0c0e'/><circle cx='50' cy='50' r='30' stroke='%23e8c96e' stroke-width='3' fill='none'/><circle cx='50' cy='50' r='8' fill='%23e8c96e'/></svg>",
                   "sizes": "any", "type": "image/svg+xml"}]
    })

@app.route("/api/library")
def api_library():
    scan_library()
    return jsonify({
        album: [{"rel": rel(t).replace(os.sep, '/'),
                 "name": os.path.splitext(os.path.basename(t))[0]}
                for t in tracks]
        for album, tracks in albums.items()
    })

@app.route("/stream/<path:rel_path>")
def stream(rel_path):
    rel_path = rel_path.split('?')[0].replace('\\', os.sep).replace('/', os.sep)
    path = absp(rel_path)
    if not os.path.isfile(path):
        return "Not found", 404
    mime, _ = mimetypes.guess_type(path)
    mime = mime or "audio/mpeg"
    size = os.path.getsize(path)
    rng  = request.headers.get("Range")
    no_cache = {"Cache-Control": "no-store"}
    if rng:
        parts  = rng.replace("bytes=", "").split("-")
        start  = int(parts[0])
        end    = int(parts[1]) if parts[1] else size - 1
        length = end - start + 1
        def gen():
            with open(path, "rb") as f:
                f.seek(start); left = length
                while left > 0:
                    chunk = f.read(min(65536, left))
                    if not chunk: break
                    yield chunk; left -= len(chunk)
        return Response(gen(), 206, mimetype=mime, headers={
            "Content-Range":  f"bytes {start}-{end}/{size}",
            "Accept-Ranges":  "bytes",
            "Content-Length": str(length),
            **no_cache,
        })
    resp = send_file(path, mimetype=mime)
    resp.headers['Cache-Control'] = 'no-store'
    return resp

@app.route("/api/youtube")
def api_youtube():
    url = request.args.get("url", "").strip()
    if not url:
        return jsonify({"error": "No URL"}), 400

    def generate():
        def evt(d): return f"data: {json.dumps(d)}\n\n"

        if not HAS_YTDLP:
            yield evt({"status": "error", "error": "Run: pip install yt-dlp"}); return

        is_playlist = "playlist" in url.lower() or "list=" in url

        if is_playlist:
            try:
                with yt_dlp.YoutubeDL({"quiet": True, "extract_flat": True,
                                        "no_warnings": True}) as y:
                    info = y.extract_info(url, download=False)
            except Exception as e:
                yield evt({"status": "error", "error": str(e)}); return

            folder  = sanitize(info.get("title") or "YouTube Playlist")
            entries = info.get("entries") or []
            total   = len(entries)
            yield evt({"status": "playlist", "name": folder, "total": total})

            for i, entry in enumerate(entries, 1):
                vid_url = "https://www.youtube.com/watch?v=" + (entry.get("id") or "")
                title   = entry.get("title") or f"Track {i}"
                safe    = sanitize(title)
                yield evt({"status": "downloading", "track": title, "index": i, "total": total})
                try:
                    ytdlp_download(vid_url, title, folder)
                    # Find the actual saved file to tell iOS what to fetch
                    rel_path = find_downloaded(safe, folder)
                    yield evt({"status": "done", "track": title, "rel": rel_path})
                except Exception as e:
                    yield evt({"status": "error", "track": title, "error": str(e)})
        else:
            title = get_title(url)
            safe  = sanitize(title)
            yield evt({"status": "downloading", "track": title, "index": 1, "total": 1})
            try:
                ytdlp_download(url, title, None)
                # Find the actual saved file
                rel_path = find_downloaded(safe, None)
                yield evt({"status": "done", "track": title, "rel": rel_path})
            except Exception as e:
                yield evt({"status": "error", "track": title, "error": str(e)})

        scan_library()
        yield evt({"status": "complete"})

    return Response(
        stream_with_context(generate()),
        mimetype="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )

# ── Launch ─────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import socket, subprocess, atexit

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80)); local_ip = s.getsockname()[0]; s.close()
    except Exception:
        local_ip = "127.0.0.1"

    cert_file = os.path.join(BASE_DIR, "server.crt")
    key_file  = os.path.join(BASE_DIR, "server.key")
    ssl_ctx   = None

    def make_cert():
        try:
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048",
                "-keyout", key_file, "-out", cert_file,
                "-days", "3650", "-nodes",
                "-subj", f"/CN={local_ip}",
                "-addext", f"subjectAltName=IP:{local_ip},IP:127.0.0.1",
            ], capture_output=True, check=True)
            return True
        except Exception:
            return False

    if os.path.exists(cert_file) and os.path.exists(key_file):
        have_cert = True
    else:
        have_cert = make_cert()

    if have_cert:
        try:
            import ssl
            ssl_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ssl_ctx.load_cert_chain(cert_file, key_file)
            protocol = "https"
        except Exception:
            ssl_ctx = None
            protocol = "http"
    else:
        protocol = "http"

    print(f"\n{'─'*52}")
    print(f"  🎵  Wireless Music Server")
    print(f"{'─'*52}")
    print(f"  Local:    {protocol}://127.0.0.1:5000")
    print(f"  Network:  {protocol}://{local_ip}:5000   ← enter this in the iOS app")
    print(f"  Tracks:   {len(all_songs)}")
    print(f"  yt-dlp:   {'yes' if HAS_YTDLP else 'no  — pip install yt-dlp'}")
    if ssl_ctx:
        print(f"  HTTPS:    ✓ self-signed cert")
        print(f"{'─'*52}")
        print(f"  On iPhone:")
        print(f"  1. Open https://{local_ip}:5000 in Safari")
        print(f"  2. Tap 'Show Details' → 'visit this website' → Go")
        print(f"  3. Confirm — you only do this once")
    else:
        print(f"  HTTPS:    ✗ openssl not found (install Git for Windows)")
        print(f"{'─'*52}")
        print(f"  Open the Network URL on your phone")
    print()

    if ssl_ctx:
        app.run(host="0.0.0.0", port=5000, debug=False,
                threaded=True, ssl_context=(cert_file, key_file))
    else:
        app.run(host="0.0.0.0", port=5000, debug=False, threaded=True)
