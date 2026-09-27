#!/usr/bin/env python3
"""Скачать HQ-превью (ogg ~192 кбит/с) кандидатов с freesound.org без логина + метаданные лицензии.

  python3 tools/sounds/fetch_candidates.py <out_dir> [category ...]
Пишет <out_dir>/<cat>/<id>.ogg и <out_dir>/meta.json (id → title, user, license_url, page, preview).
"""
import json, os, re, sys, html, time, urllib.request, urllib.error
sys.path.insert(0, os.path.dirname(__file__))
from candidates import CANDIDATES

UA = {"User-Agent": "Mozilla/5.0 (deltaplan sound research)"}


def _open(url):
    for i in range(5):
        try:
            return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60)
        except urllib.error.HTTPError as e:
            if e.code < 500 or i == 4:
                raise
            time.sleep(3 * (i + 1))


def get(url):
    return _open(url).read()


def meta(sid):
    # /s/<id>/ редиректит на /people/<user>/sounds/<id>/
    r = _open(f"https://freesound.org/s/{sid}/")
    h = r.read().decode("utf-8", "replace")
    page = r.geturl()
    a = dict(re.findall(r'data-([a-z0-9-]+)="([^"]*)"', h[h.find(f'data-sound-id="{sid}"') - 200:][:3000]))
    lic = re.search(r'href="(https?://creativecommons.org/[^"]+)"', h)
    return {
        "id": sid, "page": page, "user": re.search(r"/people/([^/]+)/", page).group(1), "title": html.unescape(a.get("title", "")),
        "duration_s": float(a.get("duration", 0) or 0), "samplerate": a.get("samplerate"),
        "license": lic.group(1) if lic else "?",
        "preview": a.get("ogg", "").replace("-lq.", "-hq."),
    }


def main():
    out = sys.argv[1]
    cats = sys.argv[2:] or list(CANDIDATES)
    mpath = os.path.join(out, "meta.json")
    allm = json.load(open(mpath)) if os.path.exists(mpath) else {}
    for c in cats:
        os.makedirs(os.path.join(out, c), exist_ok=True)
        for sid in CANDIDATES[c]:
            f = os.path.join(out, c, f"{sid}.ogg")
            if str(sid) not in allm:
                allm[str(sid)] = meta(sid) | {"category": c}
                json.dump(allm, open(mpath, "w"), indent=1, ensure_ascii=False)
                time.sleep(1)
            m = allm[str(sid)]
            if not os.path.exists(f):
                open(f, "wb").write(get(m["preview"]))
            print(f'{c:8} {sid:>7} {m["duration_s"]:7.1f}s {m["license"]:48} {m["user"]}: {m["title"][:50]}')
    json.dump(allm, open(mpath, "w"), indent=1, ensure_ascii=False)


if __name__ == "__main__":
    main()
