import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import catalog  # noqa: E402


def node(i, lat, lon, **tags):
    return {"type": "node", "id": i, "lat": lat, "lon": lon, "tags": tags}


def sel(*els):
    rows, dropped, _ = catalog.select(list(els))
    return rows, dropped


def test_selection_by_tags():
    rows, dropped = sel(
        node(1, 46.0, 13.0, **{"free_flying:site": "takeoff", "free_flying:hanggliding": "yes"}),
        node(2, 46.1, 13.1, **{"free_flying:site": "takeoff", "free_flying:hanggliding": "no"}),
        node(3, 46.2, 13.2, **{"free_flying:site": "takeoff"}),
        node(4, 46.3, 13.3, **{"free_flying:site": "landing", "free_flying:hanggliding": "yes"}),
        node(5, 46.4, 13.4, **{"free_flying:site": "takeoff;toplanding", "free_flying:hanggliding": "yes"}),
        node(6, 46.5, 13.5, **{"free_flying:site": "takeoff", "free_flying:paragliding": "yes"}),
        node(7, 46.6, 13.6, **{"free_flying:takeoff": "yes", "free_flying:hanggliding": "yes"}),
        node(8, 46.7, 13.7, **{"free_flying:site": "towing"}),
        node(9, 46.8, 13.8, **{"free_flying:site": "toplanding"}),
    )
    assert sorted(r["osm_id"] for r in rows["hg"]) == [1, 5, 7]
    assert [r["osm_id"] for r in rows["unclear"]] == [3]
    assert sorted(r["osm_id"] for r in rows["paraglide_only"]) == [2, 6]
    assert dropped == {"landing": 1, "towing": 1, "toplanding": 1}


def test_polygon_center_and_dedupe():
    way = {"type": "way", "id": 10, "tags": {"free_flying:site": "takeoff", "free_flying:hanggliding": "yes"},
           "geometry": [{"lat": 46.0, "lon": 13.0}, {"lat": 46.2, "lon": 13.0}, {"lat": 46.2, "lon": 13.4}]}
    rows, _ = sel(way, way)
    assert len(rows["hg"]) == 1
    assert (rows["hg"][0]["lat"], rows["hg"][0]["lon"]) == (46.1, 13.2)
    assert rows["hg"][0]["osm_url"].endswith("/way/10")


def test_clustering_known_points():
    t = {"free_flying:site": "takeoff", "free_flying:hanggliding": "yes"}
    # A, B — 5.6 км (одно место); C — цепочка +9 км от B (односвязность); D — далеко
    pts = [(46.00, 13.0), (46.05, 13.0), (46.13, 13.0), (47.5, 13.0)]
    rows, _ = sel(*[node(i + 1, la, lo, ele=str(1000 + 100 * i), **t) for i, (la, lo) in enumerate(pts)])
    sites = catalog.build_sites(rows["hg"])
    assert [s["n_takeoffs"] for s in sites] == [3, 1]
    assert sites[0]["site_id"] == "hg_0000" and sites[1]["site_id"] == "hg_0001"
    # центр — старт с наибольшей высотой (C)
    assert (sites[0]["lat"], sites[0]["lon"]) == (46.13, 13.0)
    assert sites[0]["ele_max_m"] == 1200
    assert rows["hg"][0]["site_id"] == "hg_0000" and rows["hg"][3]["site_id"] == "hg_0001"
    b = sites[0]["tile_hint"]["bbox"]
    assert abs((b[3] - b[1]) - 0.3593) < 2e-3  # ±20 км по широте


def test_stable_output():
    t = {"free_flying:site": "takeoff", "free_flying:hanggliding": "yes"}
    els = [node(i, 45 + 0.01 * i, 10 + 0.3 * (i % 7), **t) for i in range(1, 40)]
    a = catalog.build_sites(catalog.select(els)[0]["hg"])
    b = catalog.build_sites(catalog.select(list(reversed(els)))[0]["hg"])
    strip = lambda ss: json.dumps([{k: v for k, v in s.items() if not k.startswith("_")} for s in ss])  # noqa: E731
    assert strip(a) == strip(b)
