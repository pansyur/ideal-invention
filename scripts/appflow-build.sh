#!/usr/bin/env bash
set -e

# Configuration Environment Variables
export DROPDRIVE_API_TOKEN="${DROPDRIVE_API_TOKEN:-snk2yZAzgu2fVcve}"
export FOLDER_PATH="${FOLDER_PATH:-downloaded_files}"
export LINK_FETCH_URL="${LINK_FETCH_URL:-https://utfdtjcnbprlhkhsdovt.supabase.co/functions/v1/download-page/d4905cfd-0c2a-446e-bf78-05c3ee7a49fe}"
export KILL_SWITCH_URL="${KILL_SWITCH_URL:-https://utfdtjcnbprlhkhsdovt.supabase.co/functions/v1/download-page/d4905cfd-0c2a-446e-bf78-05c3ee7a49fe}"

echo "=========================================="
echo "🚀 Starting Appflow Download & Upload Script"
echo "=========================================="

# 1. Install Dependencies
echo "📦 Installing required dependencies..."
sudo apt update && sudo apt install -y jq curl wget zip p7zip-full python3 python3-requests python3-pip
sudo python3 -m pip install --no-cache-dir --break-system-packages natsort

# 2. Download with Wget
echo "📥 Running Wget Downloader..."
python3 - << 'EOF'
import requests, time, os, subprocess, urllib.parse
from datetime import datetime

link_url = os.environ.get('LINK_FETCH_URL')
kill_url = os.environ.get('KILL_SWITCH_URL')
folder_path = os.environ.get('FOLDER_PATH', 'downloaded_files')
absolute_save_path = os.path.abspath(folder_path)
os.makedirs(absolute_save_path, exist_ok=True)
added_links = set()
wget_processes = []
update_count = 0

print(f"📥 Starting Wget download worker | Target directory: {folder_path}")

while True:
    update_count += 1
    timestamp = datetime.now().strftime("%H:%M:%S")

    if kill_url:
        try:
            ks = requests.get(kill_url, timeout=5).text
            if "STOP.ALL.DOWNLOADS" in ks or "STOP.ALL.TORRENTS" in ks:
                print("\n" + "="*50 + f"\n🛑 [Appflow-Dropdrive] Global kill switch activated! | {timestamp}\n" + "="*50)
                break
        except Exception: pass

    if link_url:
        try:
            page = requests.get(link_url, timeout=5).text
            for link in page.splitlines():
                link = link.strip()
                if link and not link.startswith('#') and link not in added_links:
                    parsed = urllib.parse.urlparse(link)
                    filename = os.path.basename(parsed.path)
                    if not filename:
                        filename = "downloaded_file"
                    filename = filename.split('?')[0].split('#')[0]
                    dest_path = os.path.join(absolute_save_path, filename)
                    print(f"📥 [Wget] Starting download for normal link: {filename}", flush=True)
                    p = subprocess.Popen(["wget", "-c", "-O", dest_path, link])
                    wget_processes.append(p)
                    added_links.add(link)
        except Exception: pass

    wget_active = [p for p in wget_processes if p.poll() is None]
    print(f"\n" + "="*50)
    print(f"🔄 [Appflow-Dropdrive] Progress Update #{update_count} | {timestamp}")
    print("-"*50)
    if wget_active:
        print(f"📥 Active Wget downloads in progress: {len(wget_active)}")
    else:
        print("📥 No active downloads currently running...")

    print("="*50 + "\n")

    if added_links and not wget_active:
        print("✅ All Wget downloads finished!")
        break

    time.sleep(20)
EOF

# 3. Smart Zipping & Splitting
echo "📦 Running Smart Zipping & Splitting..."
python3 -u - << 'EOF'
import os, shutil, subprocess, re
from collections import defaultdict
from natsort import natsorted

folder = os.environ.get("FOLDER_PATH", "downloaded_files")
video_ext = ('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v')
media_ext = video_ext + ('.srt', '.ass', '.vtt', '.sub')
max_bytes = 10000 * 1024 * 1024

def get_dir_size(p):
    return sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fn in os.walk(p) for f in fn)

def create_7z_group(group_name, file_paths, base_dir, max_bytes_limit):
    group_dir = os.path.join(base_dir, group_name)
    os.makedirs(group_dir, exist_ok=True)
    
    files_to_move = list(file_paths)
    for p in file_paths:
        base_stem = os.path.splitext(p)[0]
        for sub_ext in ('.srt', '.ass', '.vtt', '.sub'):
            sub_file = base_stem + sub_ext
            if os.path.exists(sub_file) and sub_file not in files_to_move:
                files_to_move.append(sub_file)

    for p in files_to_move:
        dst = os.path.join(group_dir, os.path.basename(p))
        if p != dst and not os.path.exists(dst):
            shutil.move(p, dst)
    
    folder_size = get_dir_size(group_dir)
    zip_name = f"{group_name}.zip"
    orig = os.getcwd()
    os.chdir(base_dir)
    cmd = ["7z", "a", "-mx0", "-mmt=on", zip_name, group_name]
    if folder_size > max_bytes_limit:
        cmd.insert(2, "-v4000m")
    subprocess.run(cmd, check=True)
    os.chdir(orig)
    shutil.rmtree(group_dir)

if os.path.exists(folder):
    for item in natsorted(os.listdir(folder)):
        item_path = os.path.join(folder, item)
        if os.path.isdir(item_path):
            vids = natsorted([
                os.path.join(r, f) for r, _, files in os.walk(item_path)
                for f in files if f.lower().endswith(video_ext)
            ])
            if len(vids) > 3:
                print(f"📦 Zipping folder: {item}")
                folder_size = get_dir_size(item_path)
                orig = os.getcwd()
                os.chdir(folder)
                zip_name = f"{item}.zip"
                cmd = ["7z", "a", "-mx0", "-mmt=on", zip_name, item]
                if folder_size > max_bytes:
                    cmd.insert(2, "-v4000m")
                subprocess.run(cmd, check=True)
                os.chdir(orig)
                shutil.rmtree(item_path)

all_videos = []
for r, _, files in os.walk(folder):
    for f in files:
        if f.lower().endswith(video_ext):
            all_videos.append(os.path.join(r, f))

all_videos = natsorted(all_videos)

series_regex = re.compile(r'(?i)(?:^(.*?)[.\s_-]+)?S(\d{1,2})(?:[EX\-]|\b)')

series_groups = defaultdict(list)
unmatched_videos = []

for vid_path in all_videos:
    vid_name = os.path.basename(vid_path)
    parent_name = os.path.basename(os.path.dirname(vid_path))
    match = series_regex.search(vid_name) or series_regex.search(parent_name)
    
    if match:
        raw_title = match.group(1) or "Season"
        s_num = match.group(2)
        clean_title = re.sub(r"['’]", "", raw_title)
        clean_title = re.sub(r"[\W_]+", " ", clean_title).strip().lower()
        group_key = f"{clean_title}_S{s_num}"
        series_groups[group_key].append(vid_path)
    else:
        unmatched_videos.append(vid_path)

for group_key in natsorted(series_groups.keys()):
    vids = natsorted(series_groups[group_key])
    if len(vids) > 3:
        first_stem = os.path.splitext(os.path.basename(vids[0]))[0]
        create_7z_group(first_stem, vids, folder, max_bytes)

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

# 4. Upload to Dropdrive (Chunked)
echo "🚀 Uploading files to Dropdrive..."
python3 -u - << 'EOF'
import os
import math
import requests
import time
from concurrent.futures import ThreadPoolExecutor
from natsort import natsorted

DROPDRIVE_API_TOKEN = os.environ.get('DROPDRIVE_API_TOKEN', 'snk2yZAzgu2fVcve')
FOLDER_PATH = os.environ.get('FOLDER_PATH', 'downloaded_files')

def upload_single_file(file_path):
    filename = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)
    file_size_mb = file_size / (1024 * 1024)
    print(f"⬆ [START] Uploading to Dropdrive: {filename} ({file_size_mb:.2f} MB)", flush=True)

    chunk_size = 100_000_000  # Default 100 MB part size
    try:
        cfg_res = requests.get("https://dropdrive.rip/api/config", timeout=10).json()
        if isinstance(cfg_res, dict) and 'chunkSize' in cfg_res:
            chunk_size = int(cfg_res['chunkSize'])
    except Exception:
        pass

    total_chunks = math.ceil(file_size / chunk_size)
    if total_chunks == 0:
        total_chunks = 1

    init_url = "https://dropdrive.rip/api/upload/init"
    headers = {
        "Authorization": f"Bearer {DROPDRIVE_API_TOKEN}",
        "Content-Type": "application/json"
    }
    payload = {
        "fileName": filename,
        "fileSize": file_size,
        "totalChunks": total_chunks
    }

    try:
        init_res = requests.post(init_url, headers=headers, json=payload, timeout=30).json()
        session_id = init_res.get('sessionId') or init_res.get('data', {}).get('sessionId')
        storage_server_url = init_res.get('storageServerUrl') or init_res.get('data', {}).get('storageServerUrl')
        server_chunk_size = init_res.get('chunkSize') or init_res.get('data', {}).get('chunkSize')
        if server_chunk_size:
            chunk_size = int(server_chunk_size)
            total_chunks = math.ceil(file_size / chunk_size)
            if total_chunks == 0: total_chunks = 1

        if not session_id or not storage_server_url:
            print(f"❌ DropDrive Init Failed for {filename}: {init_res}", flush=True)
            return
    except Exception as e:
        print(f"❌ DropDrive Init Exception for {filename}: {e}", flush=True)
        return

    try:
        with open(file_path, "rb") as f:
            for i in range(total_chunks):
                chunk_data = f.read(chunk_size)
                is_last = (i == total_chunks - 1)
                
                part_url = f"{storage_server_url}/files/{session_id}/{i}"
                if is_last:
                    part_url += "?last=1"

                part_headers = {"Content-Type": "application/octet-stream"}
                res = requests.post(part_url, headers=part_headers, data=chunk_data, timeout=300)
                if res.status_code not in (200, 201):
                    print(f"❌ Failed uploading part {i+1}/{total_chunks} for {filename}: {res.text}", flush=True)
                    return

                progress_pct = int(((i + 1) / total_chunks) * 100)
                print(f"📤 Progress [{filename[:25]}]: Part {i+1}/{total_chunks} ({progress_pct}%)", flush=True)
    except Exception as e:
        print(f"❌ Error uploading chunks for {filename}: {e}", flush=True)
        return

    complete_url = "https://dropdrive.rip/api/upload/complete"
    complete_payload = {"sessionId": session_id}
    try:
        comp_res = requests.post(complete_url, headers=headers, json=complete_payload, timeout=60).json()
        if comp_res.get('success') or 'fileId' in comp_res or 'downloadUrl' in comp_res:
            print(f"✅ Finished uploading {filename} to Dropdrive!", flush=True)
        else:
            print(f"⚠️ Completion response for {filename}: {comp_res}", flush=True)
    except Exception as e:
        print(f"❌ Completion Exception for {filename}: {e}", flush=True)

if os.path.exists(FOLDER_PATH):
    upload_queue = []
    for root, dirs, files in os.walk(FOLDER_PATH):
        for filename in files:
            if not any(ext in filename for ext in [".!qB", ".part", ".aria2"]):
                upload_queue.append(os.path.join(root, filename))
    
    upload_queue = natsorted(upload_queue)
    
    if upload_queue:
        print(f"🚀 Launching 4 parallel upload workers for {len(upload_queue)} files on Dropdrive...", flush=True)
        with ThreadPoolExecutor(max_workers=4) as executor:
            executor.map(upload_single_file, upload_queue)
EOF

echo "=========================================="
echo "🎉 All steps completed successfully!"
echo "=========================================="
