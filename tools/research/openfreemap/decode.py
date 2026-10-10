"""Декодировать кеш тайлов OFM в метры места (та же проекция, что osm_stage.gd: Proj) -> ofm_<loc>.pkl"""
import gzip, json, math, os, pickle, sys, glob, collections
import mapbox_vector_tile as mvt
LOC = sys.argv[1] if len(sys.argv) > 1 else "aushkul"
osm = json.load(open(f"/home/greg/deltaplan/data/terrain/{LOC}/osm.json"))
lat0, lon0 = osm["center_lat"], osm["center_lon"]
R = 6371008.8; m_lat = R * math.pi / 180; m_lon = m_lat * math.cos(math.radians(lat0))
Z = 14; N = 2 ** Z; EXT = 4096
def ll(tx, ty, px, py):
    fx = (tx + px / EXT) / N; fy = (ty + py / EXT) / N
    lon = fx * 360 - 180; lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * fy))))
    return ((lon - lon0) * m_lon, -(lat - lat0) * m_lat)
def conv(g, tx, ty):
    t = g["type"]; c = g["coordinates"]
    f = lambda pts: [ll(tx, ty, p[0], p[1]) for p in pts]
    if t == "Point": return t, ll(tx, ty, *c)
    if t == "MultiPoint": return t, f(c)
    if t == "LineString": return t, f(c)
    if t == "MultiLineString": return t, [f(l) for l in c]
    if t == "Polygon": return t, [f(r) for r in c]
    if t == "MultiPolygon": return t, [[f(r) for r in p] for p in c]
out = collections.defaultdict(list)
for p in glob.glob(f"/home/greg/deltaplan_data/openfreemap/tiles/{LOC}/*.pbf"):
    if os.path.getsize(p) == 0: continue
    _, tx, ty = os.path.basename(p)[:-4].split("_"); tx, ty = int(tx), int(ty)
    d = mvt.decode(gzip.decompress(open(p, "rb").read()), y_coord_down=True)
    for lname, layer in d.items():
        for ft in layer["features"]:
            gt, co = conv(ft["geometry"], tx, ty)
            out[lname].append({"props": ft["properties"], "gt": gt, "co": co, "tile": (tx, ty)})
pickle.dump(dict(out), open(f"/home/greg/deltaplan_data/openfreemap/ofm_{LOC}.pkl", "wb"))
print({k: len(v) for k, v in out.items()})
