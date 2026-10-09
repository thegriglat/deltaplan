import json, pickle, matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
ref = json.load(open("/home/greg/deltaplan/data/terrain/aushkul/osm.json"))
ofm = pickle.load(open("/home/greg/deltaplan_data/openfreemap/ofm_aushkul.pkl", "rb"))
cx, cz, h = 0, 0, 3000
fig, ax = plt.subplots(figsize=(8, 8), dpi=90)
for r in ref["roads"]:
    p = r["p"]; ax.plot(p[0::2], p[1::2], color="#d33", lw=3.5, alpha=.45, solid_capstyle="round")
for f in ofm["transportation"]:
    if f["props"].get("class") in ("rail",): continue
    ls = [f["co"]] if f["gt"] == "LineString" else f["co"]
    for l in ls: ax.plot([a for a, b in l], [b for a, b in l], color="#06c", lw=0.8)
ax.set_xlim(cx-h, cx+h); ax.set_ylim(cz+h, cz-h); ax.set_aspect("equal")
ax.set_title("Аушкуль, 6x6 км у центра: эталон Overpass (красный, широко) и OFM z14 (синий, тонко)", fontsize=8)
fig.savefig("results/overlay_roads.jpg", bbox_inches="tight", pil_kwargs={"quality": 70})
