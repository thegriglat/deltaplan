"""Сравнение OFM z14 с эталоном osm.json по слоям -> results/compare_<loc>.json + overlay jpg"""
import json, pickle, sys, collections
from shapely.geometry import LineString, Polygon, Point, box, MultiLineString
from shapely.ops import unary_union
from shapely import make_valid
LOC = sys.argv[1] if len(sys.argv) > 1 else "aushkul"
ref = json.load(open(f"/home/greg/deltaplan/data/terrain/{LOC}/osm.json"))
ofm = pickle.load(open(f"/home/greg/deltaplan_data/openfreemap/ofm_{LOC}.pkl", "rb"))
H = 20000.0; BOX = box(-H, -H, H, H)
pairs = lambda p: list(zip(p[0::2], p[1::2]))
def lines(f):
    if f["gt"] == "LineString": return [LineString(f["co"])]
    return [LineString(l) for l in f["co"] if len(l) > 1]
def polys(f):
    if f["gt"] == "Polygon": return [Polygon(f["co"][0], f["co"][1:])]
    return [Polygon(p[0], p[1:]) for p in f["co"]]
def U(geoms): return unary_union([make_valid(g) if not g.is_valid else g for g in geoms]).intersection(BOX) if geoms else LineString()
res = {}
# ---- дороги
REFC = {"track": "track", "residential": "minor", "unclassified": "minor", "service": "service", "tertiary": "tertiary", "secondary": "secondary", "primary": "primary"}
rg = collections.defaultdict(list)
for r in ref["roads"]:
    if len(r["p"]) >= 4: rg[r["t"]].append(LineString(pairs(r["p"])))
og = collections.defaultdict(list)
for f in ofm["transportation"]:
    c = f["props"].get("class")
    og[c].extend(lines(f))
rU = {k: U(v) for k, v in rg.items()}; oU = {k: U(v) for k, v in og.items()}
roads = {"ref_by_class_km": {k: round(v.length/1000, 1) for k, v in rU.items()},
         "ofm_by_class_km": {k: round(v.length/1000, 1) for k, v in oU.items()}}
# сравнение по соответствующим классам (OFM minor = residential+unclassified+living_street)
def cmp(refgeom, ofmgeom, tol=10.0):
    if refgeom.is_empty or ofmgeom.is_empty: return None
    rb = ofmgeom.buffer(tol); ob = refgeom.buffer(tol)
    return {"ref_km": round(refgeom.length/1000, 1), "ofm_km": round(ofmgeom.length/1000, 1),
            "ref_covered_by_ofm": round(refgeom.intersection(rb).length / refgeom.length, 3),
            "ofm_covered_by_ref": round(ofmgeom.intersection(ob).length / ofmgeom.length, 3)}
groups = {"track": (["track"], ["track"]), "minor(residential+unclassified)": (["residential", "unclassified"], ["minor"]),
          "service": (["service"], ["service"]), "tertiary": (["tertiary"], ["tertiary"]),
          "secondary": (["secondary"], ["secondary"]), "primary": (["primary"], ["primary"]),
          "ALL_vehicle(no track)": (["residential", "unclassified", "service", "tertiary", "secondary", "primary"], ["minor", "service", "tertiary", "secondary", "primary", "trunk", "motorway"]),
          "ALL_with_track": (list(rU), ["minor", "service", "tertiary", "secondary", "primary", "trunk", "motorway", "track"])}
roads["compare_10m"] = {}
for g, (rc, oc) in groups.items():
    roads["compare_10m"][g] = cmp(unary_union([rU[k] for k in rc if k in rU]), unary_union([oU[k] for k in oc if k in oU]))
roads["compare_30m_ALL_with_track"] = cmp(unary_union(list(rU.values())), unary_union([oU[k] for k in ["minor","service","tertiary","secondary","primary","trunk","motorway","track"] if k in oU]), 30.0)
roads["ofm_other_km"] = {k: round(oU[k].length/1000, 1) for k in oU if k in ("path", "rail", "pier", "bridge", "transit", "aerialway", "ferry", "busway", "raceway", "bus_guideway", "motorway_construction")}
# вершины: насколько OFM грубее
rv = sum(len(pairs(r["p"])) for r in ref["roads"] if r["t"] != "track"); ov = sum(len(f["co"]) if f["gt"]=="LineString" else sum(len(l) for l in f["co"]) for f in ofm["transportation"] if f["props"].get("class") not in ("track","path","rail"))
roads["vertices_nontrack"] = {"ref": rv, "ofm_with_tile_dups": ov}
res["roads"] = roads
# ---- вода
rl = [make_valid(Polygon(pairs(l["p"]), [pairs(h) for h in l.get("h", [])])) for l in ref["water"]["lakes"] if len(l["p"]) >= 6]
rW = U(rl)
ow = [p for f in ofm["water"] for p in polys(f)]
oW = U(ow)
inter = rW.intersection(oW).area; un = rW.union(oW).area
water = {"ref_area_km2": round(rW.area/1e6, 2), "ofm_area_km2": round(oW.area/1e6, 2), "IoU": round(inter/un, 3),
         "ref_polygons": len(rl), "ofm_features": len(ofm["water"])}
big = [p for p in (rW.geoms if hasattr(rW, "geoms") else [rW]) if p.area > 10000]
bigU = unary_union(big); bigO = unary_union([p for p in (oW.geoms if hasattr(oW,"geoms") else [oW]) if p.area > 10000])
water["IoU_gt_1ha"] = round(bigU.intersection(bigO).area / bigU.union(bigO).area, 3)
water["n_gt_1ha"] = {"ref": len(big), "ofm": len(bigO.geoms) if hasattr(bigO,"geoms") else 1}
rr = U([LineString(pairs(r["p"])) for r in ref["water"]["rivers"] if len(r["p"]) >= 4])
orr = U([l for f in ofm["waterway"] for l in lines(f)])
water["waterway_km"] = {"ref": round(rr.length/1000, 1), "ofm": round(orr.length/1000, 1),
    "ref_by_t_km": {t: round(U([LineString(pairs(r['p'])) for r in ref['water']['rivers'] if r['t']==t and len(r['p'])>=4]).length/1000,1) for t in ("river","stream","canal")},
    "ofm_by_class_km": {c: round(U([l for f in ofm['waterway'] if f['props'].get('class')==c for l in lines(f)]).length/1000,1) for c in {f['props'].get('class') for f in ofm['waterway']}},
    "ref_covered_by_ofm_20m": round(rr.intersection(orr.buffer(20)).length/rr.length, 3), "ofm_covered_by_ref_20m": round(orr.intersection(rr.buffer(20)).length/orr.length, 3)}
res["water"] = water
# ---- посёлки
op = {}
for f in ofm["place"]:
    n = f["props"].get("name:ru") or f["props"].get("name"); k = (n, round(f["co"][0]/50), round(f["co"][1]/50))
    op[k] = (n, f["props"]["class"], f["co"])
dd = {}
for n, c, co in op.values(): dd.setdefault((n, c), co)
inbox = {k: co for k, co in dd.items() if abs(co[0]) <= H and abs(co[1]) <= H}
rp = [(p["n"], p["t"], (p["x"], p["z"])) for p in ref["places"]]
matched = 0; miss = []
for n, t, (x, z) in rp:
    hit = [k for k, co in inbox.items() if k[0] == n and ((co[0]-x)**2 + (co[1]-z)**2) ** .5 < 500]
    if hit: matched += 1
    else: miss.append((n, t))
refn = {n for n, _, _ in rp}
extra = [(k[0], k[1]) for k in inbox if k[0] not in refn]
res["places"] = {"ref": len(rp), "ofm_unique_in_box": len(inbox), "ofm_by_class": dict(collections.Counter(k[1] for k in inbox)),
                 "ref_matched_by_name<500m": matched, "ref_missing_in_ofm": miss, "ofm_extra_count": len(extra), "ofm_extra_sample": extra[:12]}
# ---- здания
rb = [Point(b[0], b[1]) for b in ref["buildings"]]
ob = [p for f in ofm["building"] for p in polys(f)]
oBU = unary_union(ob)
ob_u = list(oBU.geoms) if hasattr(oBU, "geoms") else [oBU]
ob_in = [p for p in ob_u if BOX.contains(p.centroid)]
rbpts = unary_union(rb)
near = sum(1 for p in rb if oBU.distance(p) < 15)
res["buildings"] = {"ref_count": len(rb), "ofm_features": len(ofm["building"]), "ofm_polygons_in_box": len(ob_in),
                    "ref_with_ofm_within_15m": near, "ref_area_ha": round(sum(b[2]*b[3] for b in ref["buildings"])/1e4, 1),
                    "ofm_area_ha": round(sum(p.area for p in ob_in)/1e4, 1),
                    "ofm_housenumber_points_dedup": len({(round(f['co'][0][0] if f['gt']!='Point' else f['co'][0]), round(f['co'][0][1] if f['gt']!='Point' else f['co'][1])) for f in ofm['housenumber']})}
res["power"] = {"ref_lines": len(ref["power"]), "ofm_layers_with_power": [l for l in ofm if "power" in l],
                "ofm_poi_classes_power": [f["props"].get("class") for f in ofm["poi"] if "power" in str(f["props"].get("class"))][:3]}
res["layers_feature_counts_with_tile_dups"] = {k: len(v) for k, v in ofm.items()}
json.dump(res, open(f"results/compare_{LOC}.json", "w"), indent=1, ensure_ascii=False, default=str)
print(json.dumps(res, indent=1, ensure_ascii=False, default=str))
