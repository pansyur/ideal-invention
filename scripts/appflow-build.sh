#!/usr/bin/env bash
set -e

echo "📦 [1/5] Installing dependencies..."
if command -v apt-get &> /dev/null; then
    apt-get update -qq
    apt-get install -y -qq p7zip-full python3 python3-requests python3-pip curl qbittorrent-nox
elif command -v brew &> /dev/null; then
    brew update
    brew install p7zip python qbittorrent-cli
fi

python3 -m pip install --no-cache-dir --break-system-packages magnet2torrent requests natsort || pip3 install magnet2torrent requests natsort

echo "🧲 [2/5] Converting magnets to torrents via magnet2torrent..."
mkdir -p downloads torrents
python3 - << 'EOF'
import asyncio
import os
import requests
from urllib.parse import urlparse
from magnet2torrent import Magnet2Torrent

link_url = "https://pink-script-snap.lovable.app/api/public/page/b0b7eba2-8a28-4cca-bae0-6012416821d6.txt"

async def main():
    try:
        ks = requests.get(link_url, timeout=10).text
        if "STOP.ALL.TORRENTS" in ks:
            print("🛑 Global kill switch active.")
            return
            
        for i, link in enumerate(ks.splitlines()):
            link = link.strip()
            if link and not link.startswith('#') and not link.endswith(' NO'):
                if link.startswith('magnet:'):
                    print(f"📥 Converting magnet: {link[:50]}...", flush=True)
                    try:
                        m2t = Magnet2Torrent(link)
                        filename, torrent_data = await asyncio.wait_for(m2t.retrieve_torrent(), timeout=30)
                        torrent_path = os.path.join("torrents", f"{filename}.torrent")
                        with open(torrent_path, "wb") as f:
                            f.write(torrent_data)
                        print(f"✅ Saved torrent: {torrent_path}")
                    except Exception as e:
                        fallback_path = os.path.join("torrents", f"fallback_{i}.magnet")
                        with open(fallback_path, "w") as mf:
                            mf.write(link)
                        print(f"⚠️ Magnet conversion failed ({e}). Queuing raw magnet fallback: {fallback_path}")
                elif link.startswith('http'):
                    try:
                        tor_data = requests.get(link, timeout=15).content
                        parsed = urlparse(link)
                        filename = os.path.basename(parsed.path) or f"download_{i}.torrent"
                        if not filename.endswith('.torrent'):
                            filename += ".torrent"
                        torrent_path = os.path.join("torrents", filename)
                        with open(torrent_path, 'wb') as tf:
                            tf.write(tor_data)
                        print(f"✅ Saved direct .torrent file: {filename}")
                    except Exception as e:
                        print(f"❌ Failed to download torrent file ({e}): {link}")
    except Exception as e:
        print(f"Error processing links: {e}")

asyncio.run(main())
EOF

echo "🚀 [3/5] Starting qbittorrent-nox & downloading files..."
python3 - << 'EOF'
import os
import glob
import time
import subprocess
import requests

DOWNLOAD_DIR = os.path.abspath("downloads")
TORRENT_DIR = os.path.abspath("torrents")
QBT_URL = "http://127.0.0.1:8080"

# 1. Generate qBittorrent configuration to bypass WebUI auth on localhost
config_dir = os.path.expanduser("~/.config/qBittorrent")
os.makedirs(config_dir, exist_ok=True)
config_file = os.path.join(config_dir, "qBittorrent.conf")

config_content = f"""[LegalNotice]
Accepted=true

[Preferences]
Downloads\\SavePath={DOWNLOAD_DIR}
WebUI\\Port=8080
WebUI\\LocalHostAuth=false
WebUI\\AuthSubnetWhitelist=127.0.0.1/32
WebUI\\AuthSubnetWhitelistEnabled=true
Queueing\\QueueingEnabled=false
"""

with open(config_file, "w") as f:
    f.write(config_content)

# 2. Start qbittorrent-nox daemon
print("🚀 Launching qbittorrent-nox daemon...")
qbt_proc = subprocess.Popen(["qbittorrent-nox"])

# Wait for WebUI to be ready
connected = False
for _ in range(20):
    try:
        res = requests.get(f"{QBT_URL}/api/v2/app/version", timeout=2)
        if res.status_code == 200:
            print(f"✅ Connected to qBittorrent WebUI v{res.text.strip()}")
            connected = True
            break
    except Exception:
        time.sleep(1)

if not connected:
    print("❌ Failed to start or connect to qbittorrent-nox.")
    qbt_proc.terminate()
    exit(1)

# 3. Queue Torrents & Magnets into qBittorrent
torrent_files = glob.glob(os.path.join(TORRENT_DIR, "*.torrent"))
magnet_files = glob.glob(os.path.join(TORRENT_DIR, "*.magnet"))

if not torrent_files and not magnet_files:
    print("⚠️ No torrent or magnet files found to download.")
    requests.post(f"{QBT_URL}/api/v2/app/shutdown")
    exit(0)

for t_file in torrent_files:
    try:
        with open(t_file, 'rb') as f:
            requests.post(
                f"{QBT_URL}/api/v2/torrents/add",
                files={'torrents': f},
                data={'savepath': DOWNLOAD_DIR}
            )
        print(f"🧲 Added torrent file: {os.path.basename(t_file)}")
    except Exception as e:
        print(f"❌ Failed to add {t_file}: {e}")

for m_file in magnet_files:
    try:
        with open(m_file, 'r') as mf:
            magnet_uri = mf.read().strip()
        if magnet_uri:
            requests.post(
                f"{QBT_URL}/api/v2/torrents/add",
                data={'urls': magnet_uri, 'savepath': DOWNLOAD_DIR}
            )
            print(f"🧲 Added magnet fallback: {os.path.basename(m_file)}")
    except Exception as e:
        print(f"❌ Failed to parse magnet from {m_file}: {e}")

# 4. Monitor Downloads via Web API
print("\n🚀 Monitoring qBittorrent downloads...")

def format_eta(seconds):
    if seconds <= 0 or seconds >= 8640000:
        return "Calculating..."
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h > 0 else f"{m:02d}:{s:02d}"

while True:
    try:
        info_res = requests.get(f"{QBT_URL}/api/v2/torrents/info", timeout=5)
        torrents = info_res.json()
    except Exception as e:
        print(f"⚠️ Error fetching torrent status: {e}")
        time.sleep(5)
        continue

    if not torrents:
        print("⏳ Waiting for torrents to initialize in queue...")
        time.sleep(3)
        continue

    all_completed = True
    for t in torrents:
        name = t.get("name", "Unknown Torrent")
        progress = t.get("progress", 0) * 100
        state = t.get("state", "")
        dl_speed = t.get("dlspeed", 0) / 1024  # KB/s
        num_seeds = t.get("num_seeds", 0)
        eta = t.get("eta", 8640000)

        # Check if completed/seeding
        is_done = progress >= 100.0 or state in ["uploading", "stalledUP", "pausedUP", "queuedUP", "completed"]

        if not is_done:
            all_completed = False
            print(
                f"📊 Progress [{name[:30]}]: {progress:.2f}% | "
                f"Down: {dl_speed:.1f} KB/s | Seeds: {num_seeds} | ETA: {format_eta(eta)}",
                flush=True
            )

    if all_completed:
        print("\n====================")
        print("🎉 FINISHED ALL QBITTORRENT DOWNLOADS:")
        print("====================")
        for t in torrents:
            print(f"✅ {t.get('name')}")
        print("====================\n")
        break

    time.sleep(5)

# 5. Clean Shutdown
print("🛑 Stopping qbittorrent-nox...")
try:
    requests.post(f"{QBT_URL}/api/v2/app/shutdown", timeout=5)
except Exception:
    qbt_proc.terminate()
EOF

echo "📦 [4/5] Running Smart Auto-Group Independent Zipping..."
python3 - << 'EOF'
import os, shutil, subprocess, re
from collections import defaultdict
from natsort import natsorted

folder = "downloads"
video_ext = ('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v')
media_ext = video_ext + ('.srt', '.ass', '.vtt', '.sub')
max_bytes = 10000 * 1024 * 1024  # 10 GB limit per independent ZIP file

def create_independent_zips(group_name, file_paths, base_dir, max_bytes_limit):
    units = []
    seen_files = set()
    file_paths = natsorted(file_paths)
    
    # Pair media files with matching subtitle sidecars
    for p in file_paths:
        if p in seen_files or not os.path.exists(p):
            continue
        unit = [p]
        seen_files.add(p)
        
        base_stem = os.path.splitext(p)[0]
        for sub_ext in ('.srt', '.ass', '.vtt', '.sub'):
            sub_file = base_stem + sub_ext
            if os.path.exists(sub_file) and sub_file not in seen_files:
                unit.append(sub_file)
                seen_files.add(sub_file)
        units.append(unit)

    if not units:
        return

    # Split into batch groups where size <= max_bytes_limit
    batches = []
    current_batch = []
    current_size = 0

    for unit in units:
        unit_size = sum(os.path.getsize(f) for f in unit if os.path.exists(f))
        if current_batch and (current_size + unit_size > max_bytes_limit):
            batches.append(current_batch)
            current_batch = []
            current_size = 0
            
        current_batch.extend(unit)
        current_size += unit_size

    if current_batch:
        batches.append(current_batch)

    # Build independent standalone .zip archives
    num_batches = len(batches)
    orig_dir = os.getcwd()
    
    # Strip commas, semicolons, and special chars to prevent curl form-data parsing failures
    safe_group_name = re.sub(r'[\\/*?:"<>|,;]', '_', group_name).strip() or "Batch"

    for idx, batch_files in enumerate(batches):
        if num_batches == 1:
            zip_filename = f"{safe_group_name}.zip"
        else:
            zip_filename = f"{safe_group_name}_part{idx + 1:02d}.zip"

        staging_parent = os.path.abspath(os.path.join(base_dir, f"_staging_{safe_group_name}"))
        staging_dir = os.path.join(staging_parent, safe_group_name)
        os.makedirs(staging_dir, exist_ok=True)

        for src in batch_files:
            if os.path.exists(src):
                dst = os.path.join(staging_dir, os.path.basename(src))
                if os.path.abspath(src) != os.path.abspath(dst):
                    shutil.move(src, dst)

        abs_base_dir = os.path.abspath(base_dir)
        zip_output_path = os.path.join(abs_base_dir, zip_filename)

        os.chdir(staging_parent)
        cmd = ["7z", "a", "-mx0", "-mmt=on", zip_output_path, safe_group_name]
        
        try:
            subprocess.run(cmd, check=True)
            print(f"📦 Created independent zip: {zip_filename}", flush=True)
        finally:
            os.chdir(orig_dir)
            shutil.rmtree(staging_parent, ignore_errors=True)

if os.path.exists(folder):
    for item in natsorted(os.listdir(folder)):
        item_path = os.path.join(folder, item)
        if os.path.isdir(item_path) and not item.startswith('_staging_'):
            all_files = [os.path.join(r, f) for r, _, files in os.walk(item_path) for f in files]
            vids = [f for f in all_files if f.lower().endswith(video_ext)]
            if len(vids) > 3:
                print(f"📦 Zipping folder directly (> 3 videos): {item}")
                create_independent_zips(item, all_files, folder, max_bytes)
                shutil.rmtree(item_path, ignore_errors=True)

all_videos = []
for r, _, files in os.walk(folder):
    for f in files:
        if f.lower().endswith(video_ext):
            all_videos.append(os.path.join(r, f))

all_videos = natsorted(all_videos)

series_regex = re.compile(r'(?i)(?:^(.*?)[.\s_-]+)?(?:S(\d{1,2})|\b(\d{1,2})x(\d{1,2})\b)')
series_groups = defaultdict(list)
remaining_tv_videos = []

for vid_path in all_videos:
    vid_name = os.path.basename(vid_path)
    parent_name = os.path.basename(os.path.dirname(vid_path))
    match = series_regex.search(vid_name) or series_regex.search(parent_name)
    if match:
        raw_title = match.group(1) or "Series"
        s_num = match.group(2) or match.group(3) or "01"
        group_key = f"{raw_title.strip('. -_').lower()}_S{s_num}"
        series_groups[group_key].append(vid_path)
        remaining_tv_videos.append(vid_path)

for group_key in natsorted(series_groups.keys()):
    vids = natsorted(series_groups[group_key])
    if len(vids) > 3:
        first_stem = os.path.splitext(os.path.basename(vids[0]))[0]
        create_independent_zips(first_stem, vids, folder, max_bytes)
        for v in vids:
            if v in remaining_tv_videos:
                remaining_tv_videos.remove(v)

if len(remaining_tv_videos) > 3:
    first_stem = os.path.splitext(os.path.basename(remaining_tv_videos[0]))[0]
    create_independent_zips(f"Batch_{first_stem}", remaining_tv_videos, folder, max_bytes)

for r, dirs, files in os.walk(folder, topdown=False):
    if r == folder: continue
    for f in natsorted(files):
        if f.lower().endswith(media_ext):
            src = os.path.join(r, f)
            dst = os.path.join(folder, f)
            if not os.path.exists(dst): 
                shutil.move(src, dst)
    shutil.rmtree(r, ignore_errors=True)
EOF

echo "📤 [5/5] Running Parallel Multi-Threaded Uploads to Filemirage..."
python3 - << 'EOF'
import os
import re
import subprocess
import requests
import time
import fcntl
from concurrent.futures import ThreadPoolExecutor
from natsort import natsorted

FILEMIRAGE_API_TOKEN = os.environ.get('FILEMIRAGE_API_TOKEN', '9QQH-DGES-CWQZ-FXNV')
FOLDER_PATH = 'downloads'

try:
    srv_res = requests.get("https://filemirage.com/api/servers", timeout=10).json()
    SERVER = srv_res['data']['server']
except Exception as e:
    print(f"Failed to fetch Filemirage server: {e}")
    exit(1)

def upload_single_file(file_path):
    filename = os.path.basename(file_path)
    
    # Pre-upload rename safety check: remove commas & semicolons to prevent curl errors
    clean_filename = re.sub(r'[,;]', '_', filename)
    if clean_filename != filename:
        new_file_path = os.path.join(os.path.dirname(file_path), clean_filename)
        os.rename(file_path, new_file_path)
        file_path = new_file_path
        filename = clean_filename

    file_size_mb = os.path.getsize(file_path) / (1024 * 1024)
    print(f"⬆️ [START] Uploading: {filename} ({file_size_mb:.2f} MB)", flush=True)
    
    curl_cmd = [
        "curl", "-X", "POST",
        f"{SERVER}/upload.php",
        "-H", f"Authorization: Bearer {FILEMIRAGE_API_TOKEN}",
        "-F", f"file=@{file_path}",
        "--max-time", "3600"
    ]
    
    proc = subprocess.Popen(curl_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    
    fd = proc.stderr.fileno()
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    
    last_print_time = time.time()
    buffer = b""
    
    while proc.poll() is None:
        try:
            chunk = proc.stderr.read(1024)
            if chunk:
                buffer += chunk
                if b'\r' in buffer or b'\n' in buffer:
                    lines = buffer.replace(b'\r', b'\n').split(b'\n')
                    buffer = lines[-1]
                    valid_lines = [L.decode('utf-8', errors='ignore').strip() for L in lines[:-1] if L.strip()]
                    if valid_lines:
                        last_line = valid_lines[-1]
                        if time.time() - last_print_time >= 30:
                            print(f"📤 Progress [{filename[:25]}]: {last_line}", flush=True)
                            last_print_time = time.time()
        except Exception:
            pass
        time.sleep(0.5)
        
    stdout, stderr = proc.communicate()
    if proc.returncode == 0:
        print(f"✅ Finished uploading {filename}: {stdout.decode('utf-8', errors='ignore').strip()}", flush=True)
    else:
        err_msg = stderr.decode('utf-8', errors='ignore').strip() if stderr else 'Unknown error'
        print(f"❌ Curl Error uploading {filename}: {err_msg}", flush=True)

if os.path.exists(FOLDER_PATH):
    upload_queue = []
    for root, dirs, files in os.walk(FOLDER_PATH):
        for filename in files:
            if not any(ext in filename for ext in [".!qB", ".part", ".aria2"]):
                upload_queue.append(os.path.join(root, filename))
    
    upload_queue = natsorted(upload_queue)
    
    if upload_queue:
        print(f"🚀 Launching 4 parallel upload workers for {len(upload_queue)} files...", flush=True)
        with ThreadPoolExecutor(max_workers=4) as executor:
            executor.map(upload_single_file, upload_queue)
EOF
