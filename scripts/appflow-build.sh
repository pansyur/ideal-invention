#!/usr/bin/env bash
set -e

echo "📦 [1/5] Installing dependencies..."
if command -v apt-get &> /dev/null; then
    apt-get update -qq
    apt-get install -y -qq python3 python3-requests python3-pip curl wget qbittorrent-nox
elif command -v brew &> /dev/null; then
    brew update
    brew install python qbittorrent-cli wget
fi

python3 -m pip install --no-cache-dir --break-system-packages magnet2torrent requests natsort || pip3 install magnet2torrent requests natsort

echo "🧲 [2/5] Converting magnets to torrents & queueing links..."
python3 - << 'EOF'
import asyncio
import os
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
        print(f"📥 [wget] Downloading regular link: {link[:60]}...", flush=
