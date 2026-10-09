"""Сетевые стадии каталога (S6): выгрузка стартов из Overpass (по тайлам мира), страны точек, тайлы Terrarium.

Всё кешируется в ~/.cache/deltaplan_osm/hg_sites/ (вне git). Клиент Overpass — tools/osm/fetch_osm.py → overpass()
(зеркала, User-Agent); для запросов с несколькими `out` (страны) — тонкая обёртка с теми же зеркалами и тем же UA.
Паузы между запросами >= PAUSE_S.
"""
import hashlib
import json
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tools" / "research" / "_legacy_terrain"))
import fetch_osm  # noqa: E402

CACHE = Path.home() / ".cache" / "deltaplan_osm" / "hg_sites"
PAUSE_S = 6.0
URLS = json.loads((ROOT / "configs" / "world_objects.json").read_text())["osm"]["overpass_urls"]
BODY = 'nwr["free_flying:site"];nwr["free_flying:takeoff"];'
TERRARIUM = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"


def log(*a):
    print(*a, flush=True)


def fetch_takeoffs(refresh=False):
    """Все free_flying:site / free_flying:takeoff по миру (всего ~6 тыс. элементов — один запрос; по тайлам
    сервер на 05.10 отвечал 504 на каждый). Кеш: raw/world.json."""
    (CACHE / "raw").mkdir(parents=True, exist_ok=True)
    path = CACHE / "raw" / "world.json"
    n_req = 0
    if path.exists() and not refresh:
        res = json.loads(path.read_text())
    else:
        log("Overpass: весь мир одним запросом")
        res = fetch_osm.overpass(URLS, BODY, (-90, -180, 90, 180), 300)
        n_req = 1
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(res))
        tmp.replace(path)
    meta_p = CACHE / "fetch_meta.json"
    if n_req or not meta_p.exists():
        meta_p.write_text(json.dumps({
            "date_utc": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
            "osm_base_timestamp": res.get("osm3s", {}).get("timestamp_osm_base", ""),
            "overpass_body": BODY, "mirrors": URLS, "requests_takeoffs": 1}, indent=1))
    return res.get("elements", [])


def _post(q, timeout_s=300):
    data = urllib.parse.urlencode({"data": q}).encode()
    for attempt in range(3 * len(URLS)):
        url = URLS[attempt % len(URLS)]
        req = urllib.request.Request(url, data=data, headers={"User-Agent": fetch_osm.USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=timeout_s + 30) as r:
                return json.loads(r.read())
        except Exception as ex:  # noqa: BLE001
            log("  Overpass", url, ex, "повтор", attempt + 1)
            time.sleep(5 * (attempt + 1))
    raise RuntimeError("Overpass недоступен")


def countries(points, batch=100):
    """points: список (lat, lon) → словарь 'lat,lon' → ISO alpha-2 ('' если не найдено). Кеш: country/<хеш>.json."""
    (CACHE / "country").mkdir(parents=True, exist_ok=True)
    pts = sorted(set((round(a, 5), round(b, 5)) for a, b in points))
    res_all, n_req = {}, 0
    for i in range(0, len(pts), batch):
        chunk = pts[i:i + batch]
        key = hashlib.sha1(json.dumps(chunk).encode()).hexdigest()[:16]
        path = CACHE / "country" / (key + ".json")
        if path.exists():
            part = json.loads(path.read_text())
        else:
            body = "".join('make pt i="%d";out;is_in(%.5f,%.5f)->.a;area.a["admin_level"="2"]["ISO3166-1"];convert area ::id=id(),iso=t["ISO3166-1"];out;'
                           % (k, la, lo) for k, (la, lo) in enumerate(chunk))
            for _try in range(4):
                j = _post("[out:json][timeout:300];" + body)
                if "remark" not in j:  # remark = ошибка выполнения/усечённый ответ — не кешировать
                    break
                log("  remark:", j["remark"][:100])
                time.sleep(30)
            else:
                raise RuntimeError("Overpass: усечённый ответ")
            n_req += 1
            part, cur = {}, None
            for el in j["elements"]:
                if el["type"] == "pt":
                    cur = int(el["tags"]["i"])
                    part["%.5f,%.5f" % chunk[cur]] = ""
                elif cur is not None:
                    iso = el.get("tags", {}).get("iso", "")
                    if iso:
                        k = "%.5f,%.5f" % chunk[cur]
                        part[k] = iso if not part[k] else min(part[k], iso)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(part))
            tmp.replace(path)
            log("страны: пачка", i // batch + 1, "/", (len(pts) + batch - 1) // batch)
            time.sleep(PAUSE_S)
        res_all.update(part)
    return res_all, n_req


def country_names():
    """ISO alpha-2 → (name:en, name:ru) одним запросом по границам admin_level=2. Кеш: country_names.json."""
    path = CACHE / "country_names.json"
    if not path.exists():
        j = _post('[out:json][timeout:300];rel["admin_level"="2"]["ISO3166-1"];'
                  'convert c iso=t["ISO3166-1"],en=t["name:en"],ru=t["name:ru"],nm=t["name"];out;')
        names = {}
        for el in j["elements"]:
            t = el.get("tags", {})
            if t.get("iso"):
                names[t["iso"]] = [t.get("en") or t.get("nm", ""), t.get("ru", "")]
        path.write_text(json.dumps(names, sort_keys=True, ensure_ascii=False))
        time.sleep(PAUSE_S)
    return json.loads(path.read_text())


def terrarium_tile(z, x, y):
    import numpy as np
    from PIL import Image
    path = CACHE / "terrarium" / str(z) / str(x) / ("%d.png" % y)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        req = urllib.request.Request(TERRARIUM.format(z=z, x=x, y=y),
                                     headers={"User-Agent": fetch_osm.USER_AGENT})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    data = r.read()
                break
            except Exception as ex:  # noqa: BLE001
                log("  terrarium", z, x, y, ex)
                time.sleep(3 * (attempt + 1))
        else:
            return None
        tmp = path.with_suffix(".part")
        tmp.write_bytes(data)
        tmp.replace(path)
        time.sleep(0.15)
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.float64)
    return a[..., 0] * 256 + a[..., 1] + a[..., 2] / 256 - 32768
