"""Мировые количества объектов OSM из taginfo (API v4, /tag/overview и /key/overview).
    python -I taginfo_counts.py results/taginfo_counts.json
Лицензия данных taginfo — ODbL (как OSM), https://taginfo.openstreetmap.org/ ."""
import json
import sys
import time
import urllib.parse
import urllib.request

KV = ["highway=motorway", "highway=trunk", "highway=primary", "highway=secondary", "highway=tertiary",
      "highway=motorway_link", "highway=trunk_link", "highway=primary_link", "highway=secondary_link",
      "highway=tertiary_link", "highway=unclassified", "highway=residential", "highway=living_street",
      "highway=road", "highway=track", "building=no", "power=line", "power=minor_line", "power=tower",
      "aerialway=cable_car", "aerialway=gondola", "aerialway=chair_lift", "aerialway=drag_lift",
      "aerialway=t-bar", "aerialway=j-bar", "aerialway=platter", "aerialway=magic_carpet", "aerialway=mixed_lift",
      "aerialway=rope_tow", "aerialway=zip_line", "aerialway=goods",
      "aeroway=aerodrome", "aeroway=airstrip", "aeroway=helipad", "aeroway=runway",
      "man_made=mast", "man_made=tower", "man_made=chimney", "generator:source=wind", "tower:type=communication",
      "railway=rail", "railway=narrow_gauge", "natural=peak", "natural=saddle", "mountain_pass=yes",
      "waterway=river", "waterway=canal", "waterway=stream"]
KEYS = ["building", "name"]


def get(path, **q):
    url = "https://taginfo.openstreetmap.org/api/4/" + path + "?" + urllib.parse.urlencode(q)
    for _ in range(3):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                return json.load(r)
        except Exception as e:  # noqa: BLE001
            err = e
            time.sleep(3)
    return {"error": str(err)}


out = {"source": "taginfo.openstreetmap.org/api/4", "date": time.strftime("%F"), "tags": {}, "keys": {}}
for kv in KV:
    k, v = kv.split("=")
    d = get("tag/overview", key=k, value=v)
    c = {x["type"]: x["count"] for x in d["data"]["counts"]} if "data" in d else d
    out["tags"][kv] = c
    print(kv, c)
for k in KEYS:
    d = get("key/overview", key=k)
    dd = d.get("data")
    cs = dd if isinstance(dd, list) else (dd or {}).get("counts", [])
    out["keys"][k] = {x["type"]: x["count"] for x in cs} if cs else d
    print(k, out["keys"][k])
open(sys.argv[1], "w").write(json.dumps(out, ensure_ascii=False, indent=1))
