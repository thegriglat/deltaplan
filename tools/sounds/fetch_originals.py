#!/usr/bin/env python3
"""Скачать ОРИГИНАЛЫ (wav/flac/aiff/…) выбранных звуков freesound через OAuth2 API.

  python3 tools/sounds/fetch_originals.py <cache_dir> [id ...]
Токен берётся из tools/freesound_token.py (в stdout этого скрипта не печатается и никуда не пишется).
Файлы: <cache_dir>/orig/<id>.<type>. Без аргументов — все id, которые используются в process_assets.py.
"""
import json, os, re, subprocess, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def token():
    return subprocess.run([sys.executable, os.path.join(HERE, "..", "freesound_token.py")],
                          check=True, capture_output=True, text=True).stdout.strip()


def used_ids():
    src = open(os.path.join(HERE, "process_assets.py")).read()
    return sorted(set(int(x) for x in re.findall(r'^\s*\("[^"]+",\s*(\d{4,7}),', src, re.M)))


def main():
    cache = sys.argv[1]
    ids = [int(x) for x in sys.argv[2:]] or used_ids()
    out = os.path.join(cache, "orig"); os.makedirs(out, exist_ok=True)
    hdr = {"Authorization": "Bearer " + token(), "User-Agent": "deltaplan"}
    for sid in ids:
        if any(f.startswith(f"{sid}.") for f in os.listdir(out)):
            continue
        info = json.load(urllib.request.urlopen(urllib.request.Request(
            f"https://freesound.org/apiv2/sounds/{sid}/?fields=id,type,license,username,samplerate,bitdepth,channels",
            headers=hdr), timeout=60))
        f = os.path.join(out, f"{sid}.{info['type']}")
        data = urllib.request.urlopen(urllib.request.Request(
            f"https://freesound.org/apiv2/sounds/{sid}/download/", headers=hdr), timeout=600).read()
        open(f, "wb").write(data)
        print(sid, info["type"], info["samplerate"], info.get("bitdepth"), info["channels"], len(data) // 1024, "KiB", info["license"])


if __name__ == "__main__":
    main()
