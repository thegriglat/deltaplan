#!/usr/bin/env python3
"""Поиск звуков на freesound.org без API-ключа (парсинг HTML поиска).

Использование:
  python3 tools/sounds/fs_search.py "wind strong" [--license cc0|by|any] [--pages 1] [--sort downloads]
Выводит: id, длительность, скачивания, пользователь, название, лицензия, URL HQ-превью (ogg).
HQ-превью (…-hq.ogg, ~192 кбит/с) доступны без логина; оригиналы (wav/flac) — только с логином/OAuth.
"""
import argparse, html, re, sys, urllib.parse, urllib.request

LIC = {"cc0": 'license:"Creative Commons 0"', "by": 'license:"Attribution"', "any": ""}
SORT = {"downloads": "num_downloads desc", "rating": "avg_rating desc", "score": "score desc"}
UA = {"User-Agent": "Mozilla/5.0 (deltaplan sound research)"}


def fetch(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30).read().decode("utf-8", "replace")


def search(q, lic="cc0", pages=1, sort="score"):
    out = []
    for p in range(1, pages + 1):
        params = {"q": q, "page": p, "s": SORT[sort]}
        if LIC[lic]:
            params["f"] = LIC[lic]
        h = fetch("https://freesound.org/search/?" + urllib.parse.urlencode(params))
        for blk in h.split('class="bw-player"')[1:]:
            a = dict(re.findall(r'data-([a-z0-9-]+)="([^"]*)"', blk[:3000]))
            if "sound-id" not in a:
                continue
            lm = re.search(r'bw-icon-(zero|by-nc|by|sampling-plus|cc)', blk)
            out.append({
                "id": a["sound-id"], "user": a.get("username"), "title": html.unescape(a.get("title", "")),
                "dur": float(a.get("duration", 0)), "dl": int(a.get("num-downloads", 0) or 0),
                "sr": a.get("samplerate"),
                "hq_ogg": a.get("ogg", "").replace("-lq.", "-hq."),
                "page": f"https://freesound.org/people/{a.get('username')}/sounds/{a['sound-id']}/",
                "lic_icon": lm.group(1) if lm else "?",
            })
    return out


def sound_license(page_url):
    """Точная лицензия со страницы звука."""
    h = fetch(page_url)
    m = re.search(r'href="(https?://creativecommons.org/[^"]+)"', h)
    return m.group(1) if m else "?"


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("q")
    ap.add_argument("--license", default="cc0", choices=LIC)
    ap.add_argument("--pages", type=int, default=1)
    ap.add_argument("--sort", default="score", choices=SORT)
    ap.add_argument("--min", type=float, default=0)
    ap.add_argument("-n", type=int, default=15)
    a = ap.parse_args()
    rows = [r for r in search(a.q, a.license, a.pages, a.sort) if r["dur"] >= a.min][: a.n]
    for r in rows:
        print(f'{r["id"]:>7} {r["dur"]:7.1f}s dl={r["dl"]:<6} {r["lic_icon"]:<6} {r["user"][:18]:<18} {r["title"][:60]}')
