import time, requests, pathlib
ROOT = pathlib.Path(__file__).parent
RAW = ROOT / "raw"
UA = "Mozilla/5.0 (X11; Linux x86_64) deltaplan-research/1.0 (non-commercial open-source hang glider sim; thegriglat@gmail.com)"
PAUSE = 1.5
_s = requests.Session(); _s.headers["User-Agent"] = UA
def get(url, dest, post=None, force=False):
    """Скачать url в RAW/dest (если ещё нет). Возвращает (статус, путь). Пауза PAUSE между запросами."""
    p = RAW / dest; p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists() and p.stat().st_size > 0 and not force:
        return 200, p
    time.sleep(PAUSE)
    try:
        r = _s.post(url, data=post, timeout=40) if post is not None else _s.get(url, timeout=40)
    except Exception as e:
        print("ERR", url, e); return 0, p
    if r.status_code == 200 and len(r.content) > 500:
        p.write_bytes(r.content)
    else:
        print(r.status_code, url)
    return r.status_code, p
