#!/usr/bin/env bash
set -e

echo "📦 [1/5] Installing dependencies..."
if command -v apt-get &> /dev/null; then
    apt-get update -qq
    apt-get install -y -qq p7zip-full python3 python3-requests python3-pip curl wget qbittorrent-nox
elif command -v brew &> /dev/null; then
    brew update
    brew install p7zip python qbittorrent-cli wget
fi

python3 -m pip install --no-cache-dir --break-system-packages magnet2torrent requests natsort || pip3 install magnet2torrent requests natsort

echo "🧲 [2/5] Converting magnets to torrents & queueing links..."
mkdir -p downloads torrents
python3 - << 'EOF'
import asyncio
import os
import re
import requests
import subprocess
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor
from magnet2torrent import Magnet2Torrent

link_url = "https://utfdtjcnbprlhkhsdovt.supabase.co/functions/v1/download-page/19e2ba61-ff6c-4d5e-a365-266ed68074bc"
processed_file = os.path.join("torrents", ".processed_links")

def load_processed():
    if os.path.exists(processed_file):
        with open(processed_file, "r") as f:
            return set(line.strip() for line in f if line.strip())
    return set()

def save_processed(links):
    with open(processed_file, "w") as f:
        for l in links:
            f.write(f"{l}\n")

def clean_filename_query_params(target_dir):
    for root, _, files in os.walk(target_dir):
        for f in files:
            if '?' in f:
                clean_name = f.split('?')[0]
                old_path = os.path.join(root, f)
                new_path = os.path.join(root, clean_name)
                try:
                    if not os.path.exists(new_path):
                        os.rename(old_path, new_path)
                    else:
                        os.rename(old_path, old_path.replace('?', '_'))
                except Exception:
                    pass

def download_wget(link, target_dir="downloads"):
    try:
        print(f"📥 [wget] Downloading regular link: {link[:60]}...", flush=True)
        cmd = ["wget", "-q", "--content-disposition", "-P", target_dir, link]
        subprocess.run(cmd, check=True)
        clean_filename_query_params(target_dir)
        print(f"✅ [wget] Finished download: {link[:60]}", flush=True)
    except Exception as e:
        print(f"❌ [wget] Failed downloading link ({e}): {link[:60]}", flush=True)

async def main():
    processed_links = load_processed()
    try:
        ks = requests.get(link_url, timeout=10).text
        if "STOP.ALL.TORRENTS" in ks:
            print("🛑 Global kill switch active.")
            return
            
        executor = ThreadPoolExecutor(max_workers=4)
        futures = []

        for i, link in enumerate(ks.splitlines()):
            link = link.strip()
            if link and not link.startswith('#') and not link.endswith(' NO') and link not in processed_links:
                processed_links.add(link)
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
                    parsed = urlparse(link)
                    clean_path = parsed.path.lower()
                    if clean_path.endswith('.torrent'):
                        try:
                            tor_data = requests.get(link, timeout=15).content
                            filename = os.path.basename(parsed.path) or f"download_{i}.torrent"
                            if not filename.endswith('.torrent'):
                                filename += ".torrent"
                            torrent_path = os.path.join("torrents", filename)
                            with open(torrent_path, 'wb') as tf:
                                tf.write(tor_data)
                            print(f"✅ Saved direct .torrent file: {filename}")
                        except Exception as e:
                            print(f"❌ Failed to download torrent file ({e}): {link}")
                    else:
                        fut = executor.submit(download_wget, link, "downloads")
                        futures.append(fut)
        
        save_processed(processed_links)
        executor.shutdown(wait=False)
    except Exception as e:
        print(f"Error processing links: {e}")

asyncio.run(main())
EOF

echo "🚀 [3/5] Starting qbittorrent-nox & downloading files..."
python3 - << 'EOF'
import os
import re
import glob
import time
import subprocess
import requests
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor

DOWNLOAD_DIR = os.path.abspath("downloads")
TORRENT_DIR = os.path.abspath("torrents")
QBT_URL = "http://127.0.0.1:8080"
link_url = "https://utfdtjcnbprlhkhsdovt.supabase.co/functions/v1/download-page/19e2ba61-ff6c-4d5e-a365-266ed68074bc"
processed_file = os.path.join(TORRENT_DIR, ".processed_links")

def load_processed():
    if os.path.exists(processed_file):
        with open(processed_file, "r") as f:
            return set(line.strip() for line in f if line.strip())
    return set()

def save_processed(links):
    with open(processed_file, "w") as f:
        for l in links:
            f.write(f"{l}\n")

def clean_filename_query_params(target_dir):
    for root, _, files in os.walk(target_dir):
        for f in files:
            if '?' in f:
                clean_name = f.split('?')[0]
                old_path = os.path.join(root, f)
                new_path = os.path.join(root, clean_name)
                try:
                    if not os.path.exists(new_path):
                        os.rename(old_path, new_path)
                    else:
                        os.rename(old_path, old_path.replace('?', '_'))
                except Exception:
                    pass

def download_wget(link, target_dir="downloads"):
    try:
        print(f"📥 [wget] Downloading regular link: {link[:60]}...", flush=True)
        cmd = ["wget", "-q", "--content-disposition", "-P", target_dir, link]
        subprocess.run(cmd, check=True)
        clean_filename_query_params(target_dir)
        print(f"✅ [wget] Finished download: {link[:60]}", flush=True)
    except Exception as e:
        print(f"❌ [wget] Failed downloading link ({e}): {link[:60]}", flush=True)

# 1. Generate qBittorrent configuration
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

# 4. Setup async pool for wget downloads & monitoring
wget_executor = ThreadPoolExecutor(max_workers=4)
wget_futures = []
processed_links = load_processed()

def handle_new_link(link):
    processed_links.add(link)
    save_processed(processed_links)
    if link.startswith('magnet:'):
        try:
            requests.post(
                f"{QBT_URL}/api/v2/torrents/add",
                data={'urls': link, 'savepath': DOWNLOAD_DIR}
            )
            print(f"🧲 Added new magnet link: {link[:50]}...")
        except Exception as e:
            print(f"❌ Failed adding magnet ({e})")
    elif link.startswith('http'):
        parsed = urlparse(link)
        if parsed.path.lower().endswith('.torrent'):
            try:
                tor_data = requests.get(link, timeout=15).content
                filename = os.path.basename(parsed.path) or "new_torrent.torrent"
                if not filename.endswith('.torrent'):
                    filename += ".torrent"
                torrent_path = os.path.join(TORRENT_DIR, filename)
                with open(torrent_path, 'wb') as tf:
                    tf.write(tor_data)
                with open(torrent_path, 'rb') as tf:
                    requests.post(
                        f"{QBT_URL}/api/v2/torrents/add",
                        files={'torrents': tf},
                        data={'savepath': DOWNLOAD_DIR}
                    )
                print(f"🧲 Added new .torrent file: {filename}")
            except Exception as e:
                print(f"❌ Failed adding .torrent ({e})")
        else:
            fut = wget_executor.submit(download_wget, link, DOWNLOAD_DIR)
            wget_futures.append(fut)

print("\n🚀 Monitoring qBittorrent and wget downloads...")

def format_eta(seconds):
    if seconds <= 0 or seconds >= 8640000:
        return "Calculating..."
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h > 0 else f"{m:02d}:{s:02d}"

last_check_time = 0
CHECK_INTERVAL = 20

while True:
    now = time.time()
    if now - last_check_time >= CHECK_INTERVAL:
        last_check_time = now
        try:
            res = requests.get(link_url, timeout=10)
            if res.status_code == 200:
                ks = res.text
                if "STOP.ALL.TORRENTS" in ks:
                    print("🛑 Global kill switch active. Stopping downloads.")
                    requests.post(f"{QBT_URL}/api/v2/app/shutdown", timeout=5)
                    exit(0)
                
                for line in ks.splitlines():
                    link = line.strip()
                    if link and not link.startswith('#') and not link.endswith(' NO') and link not in processed_links:
                        handle_new_link(link)
        except Exception:
            pass

    try:
        info_res = requests.get(f"{QBT_URL}/api/v2/torrents/info", timeout=5)
        torrents = info_res.json()
    except Exception as e:
        torrents = []

    qbt_completed = True
    if torrents:
        for t in torrents:
            name = t.get("name", "Unknown Torrent")
            progress = t.get("progress", 0) * 100
            state = t.get("state", "")
            dl_speed = t.get("dlspeed", 0) / 1024  # KB/s
            num_seeds = t.get("num_seeds", 0)
            eta = t.get("eta", 8640000)

            is_done = progress >= 100.0 or state in ["uploading", "stalledUP", "pausedUP", "queuedUP", "completed"]

            if not is_done:
                qbt_completed = False
                print(
                    f"📊 Progress [{name[:30]}]: {progress:.2f}% | "
                    f"Down: {dl_speed:.1f} KB/s | Seeds: {num_seeds} | ETA: {format_eta(eta)}",
                    flush=True
                )

    wget_completed = all(f.done() for f in wget_futures)

    if not torrents and not wget_futures and not processed_links:
        print("⏳ Waiting for downloads to initialize...")
        time.sleep(3)
        continue

    if qbt_completed and wget_completed:
        print("\n====================")
        print("🎉 FINISHED ALL DOWNLOADS:")
        print("====================")
        for t in torrents:
            print(f"✅ {t.get('name')}")
        print("====================\n")
        break

    time.sleep(5)

wget_executor.shutdown(wait=True)

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

    num_batches = len(batches)
    orig_dir = os.getcwd()
    
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

for vid_path in all_videos:
    vid_name = os.path.basename(vid_path)
    parent_name = os.path.basename(os.path.dirname(vid_path))
    match = series_regex.search(vid_name) or series_regex.search(parent_name)
    if match:
        raw_title = match.group(1) or "Series"
        s_num = (match.group(2) or match.group(3) or "1").zfill(2)
        clean_title = re.sub(r'[^a-zA-Z0-9]', '', raw_title).lower() or "series"
        group_key = f"{clean_title}_S{s_num}"
        series_groups[group_key].append(vid_path)

for group_key in natsorted(series_groups.keys()):
    vids = natsorted(series_groups[group_key])
    if len(vids) > 3:
        first_stem = os.path.splitext(os.path.basename(vids[0]))[0]
        create_independent_zips(first_stem, vids, folder, max_bytes)

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

echo "📤 [5/5] Running Parallel Multi-Threaded Uploads to Vikingfile..."
python3 - << 'EOF'
import os
import subprocess
import requests
import time
import fcntl
import threading
from concurrent.futures import ThreadPoolExecutor
from natsort import natsorted

VIKINGFILE_API_TOKEN = '8IcySE8jai'
FOLDER_PATH = 'downloads'
LINK_URL = "https://utfdtjcnbprlhkhsdovt.supabase.co/functions/v1/download-page/354dcb17-48af-495d-b98f-c9c1bd268c33"

def check_kill_switch():
    while True:
        time.sleep(20)
        try:
            res = requests.get(LINK_URL, timeout=5)
            if res.status_code == 200 and "STOP.ALL.TORRENTS" in res.text:
                print("🛑 Global kill switch active. Exiting...", flush=True)
                os._exit(0)
        except Exception:
            pass

threading.Thread(target=check_kill_switch, daemon=True).start()

def get_upload_server():
    r = requests.get("https://vikingfile.com/api/get-server", timeout=15).json()
    server = r.get("server")
    if not server:
        raise RuntimeError(f"No server in response: {r}")
    return server

def curl_quote(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

def upload_single_file(file_path):
    filename = os.path.basename(file_path)
    file_size_mb = os.path.getsize(file_path) / (1024 * 1024)
    print(f"⬆️ [START] Uploading to Vikingfile: {filename} ({file_size_mb:.2f} MB)", flush=True)

    for attempt in range(1, 4):
        try:
            target_url = get_upload_server()
        except Exception as e:
            print(f"⚠️ get-server failed for {filename} (attempt {attempt}): {e}", flush=True)
            time.sleep(5)
            continue

        curl_cmd = [
            "curl", "-f", "-X", "POST",
            target_url,
            "--form-string", f"user={VIKINGFILE_API_TOKEN}",
            "-F", f'file=@"{curl_quote(file_path)}";filename="{curl_quote(filename)}"',
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
                        if valid_lines and time.time() - last_print_time >= 30:
                            print(f"📤 Progress [{filename[:25]}]: {valid_lines[-1]}", flush=True)
                            last_print_time = time.time()
            except Exception:
                pass
            time.sleep(0.5)

        stdout, stderr = proc.communicate()
        out_msg = stdout.decode('utf-8', errors='ignore').strip()
        err_msg = stderr.decode('utf-8', errors='ignore').strip().splitlines()
        err_tail = err_msg[-1] if err_msg else 'Unknown error'

        if proc.returncode == 0 and out_msg and not out_msg.lower().startswith("<html"):
            print(f"✅ Finished uploading {filename}: {out_msg}", flush=True)
            return

        print(f"⚠️ Attempt {attempt}/3 failed for {filename} via {target_url}: {out_msg or err_tail}", flush=True)
        time.sleep(3)

    print(f"❌ Failed to upload {filename} after 3 attempts.", flush=True)

def safe_upload(file_path):
    try:
        upload_single_file(file_path)
    except Exception as e:
        print(f"❌ Exception uploading {file_path}: {e}", flush=True)

if os.path.exists(FOLDER_PATH):
    upload_queue = []
    for root, dirs, files in os.walk(FOLDER_PATH):
        for filename in files:
            if not any(ext in filename for ext in [".!qB", ".part", ".aria2"]):
                upload_queue.append(os.path.join(root, filename))

    upload_queue = natsorted(upload_queue)

    if upload_queue:
        print(f"🚀 Launching 4 parallel upload workers for {len(upload_queue)} files to Vikingfile...", flush=True)
        with ThreadPoolExecutor(max_workers=4) as executor:
            list(executor.map(safe_upload, upload_queue))
EOF
