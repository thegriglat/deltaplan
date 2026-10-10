"""Тесты regions.py офлайн: обрезанный снимок index-v1.json, сеть и osmtiles — заглушки."""
import io
import json
import os
import stat
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import regions as R  # noqa: E402

FIX = os.path.join(HERE, "data", "geofabrik", "index-v1.json")
SIZES_GB = {  # HEAD-размеры заглушки
    "europe": 30, "africa": 8, "russia": 4, "germany": 4.5, "dach": 6, "alps": 3, "britain-and-ireland": 3.5,
    "united-kingdom": 1.9, "great-britain": 1.6, "ireland-and-northern-ireland": 0.5, "austria": 0.8,
    "switzerland": 0.5, "france": 4.0, "italy": 1.7, "slovenia": 0.3, "monaco": 0.01, "bayern": 1.0,
    "baden-wuerttemberg": 0.9, "isle-of-man": 0.1, "guernsey-jersey": 0.05, "liechtenstein": 0.02, "algeria": 0.2, "central-fed-district": 2.5,
}


class FakeResp:
    def __init__(self, body=b"", headers=None):
        self._b, self.headers = body, headers or {}

    def read(self):
        return self._b


def fake_http(url, method="GET", timeout=60):
    if url.endswith("index-v1.json"):
        return FakeResp(open(FIX, "rb").read())
    if url.endswith(".poly"):
        return FakeResp(b"poly\n1\n 0 0\n 1 0\n 1 1\nEND\nEND\n")
    rid = url.rsplit("/", 1)[1].replace("-latest.osm.pbf", "")
    if method == "HEAD" and rid in SIZES_GB:
        return FakeResp(headers={"Content-Length": str(int(SIZES_GB[rid] * 1e9)), "Last-Modified": "x"})
    raise AssertionError("неожиданный запрос %s %s" % (method, url))


def fake_osmtiles(dirpath):
    p = os.path.join(dirpath, "osmtiles")
    with open(p, "w") as f:
        f.write("#!/bin/sh\nprintf '1 1\\n1 2\\n'\nif [ \"$3\" != \"${3%germany.poly}\" ]; then printf '1 2\\n1 3\\n'; fi\n")
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    return p


def tree():
    return R.Tree(json.load(open(FIX)))


class Geometry(unittest.TestCase):
    def test_area_and_overlap(self):
        t = tree()
        self.assertGreater(t.mask("germany").area(), t.mask("bayern").area() * 3)
        a = t.mask("bayern").intersect_area(t.mask("germany")) / t.mask("bayern").area()
        self.assertGreater(a, 0.98)
        self.assertLess(t.mask("slovenia").intersect_area(t.mask("bayern")) / t.mask("slovenia").area(), 0.05)

    def test_drop_covered(self):
        t = tree()
        kept, dropped = R.drop_covered(t, t.kids("europe"))
        for comp in ("dach", "alps"):
            self.assertIn(comp, dropped)
        for real in ("germany", "france", "austria", "slovenia", "switzerland"):
            self.assertIn(real, kept)


class Choose(unittest.TestCase):
    def setUp(self):
        t = tree()
        self.t = t
        self.chosen, self.warns, self.over, self.comps = R.choose(
            t, lambda i: int(SIZES_GB[i] * 1e9), int(2e9))
        self.chosen, self.removed = R.drop_contained(t, R.prune_nested(t, self.chosen))

    def test_set(self):
        c = set(self.chosen)
        self.assertNotIn("dach", c)
        self.assertNotIn("alps", c)
        self.assertNotIn("europe", c)
        self.assertTrue({"austria", "france", "italy", "slovenia",
                         "ireland-and-northern-ireland", "algeria"} <= c)
        self.assertEqual(len({"great-britain", "united-kingdom"} & c), 1)  # вложенные: остаётся один
        # у germany в снимке только два из 16 детей: покрытие < 99 % — целиком, как исключение
        self.assertIn("germany", c)
        self.assertEqual(self.over.count("germany"), 1)
        self.assertNotIn("bayern", c)
        # russia: один ребёнок, но он > лимита и без детей — исключение
        self.assertIn("central-fed-district", self.over)

    def test_no_nested_no_overlap(self):
        self.assertEqual(R.prune_nested(self.t, self.chosen), self.chosen)
        masks = {i: self.t.mask(i).eroded() for i in self.chosen}
        for a in self.chosen:
            for b in self.chosen:
                if a < b and a not in ("france",) and b not in ("france",):
                    ar = min(masks[a].area(), masks[b].area())
                    if ar:
                        self.assertLess(100 * masks[a].intersect_area(masks[b]) / ar, 1.0, (a, b))


class PlanCheck(unittest.TestCase):
    def test_plan_resume_check(self):
        R.http = fake_http
        R.HEAD_DELAY_S = 0
        with tempfile.TemporaryDirectory() as d:
            work = os.path.join(d, "w")
            exe = fake_osmtiles(d)
            # первый запуск без osmtiles: набор и .poly, cover ещё нет
            self.assertEqual(R.main(["plan", "--work", work]), 0)
            data = R.load_json(os.path.join(work, "regions.json"))
            ids = [r["id"] for r in data["regions"]]
            self.assertIn("austria", ids)
            self.assertTrue(os.path.exists(os.path.join(work, "poly", "austria.poly")))
            self.assertIsNone(data["regions"][0]["tiles"])
            self.assertEqual(R.check_stats(work)["cover_missing"], len(ids))
            # повтор: ничего не качает (заглушка сети падает на любом запросе)
            R.http = lambda *a, **k: (_ for _ in ()).throw(AssertionError("сеть при повторе"))
            self.assertEqual(R.main(["plan", "--work", work, "--osmtiles", exe]), 0)
            data = R.load_json(os.path.join(work, "regions.json"))
            self.assertTrue(all(r["tiles"] for r in data["regions"]))
            s = R.check_stats(work)
            self.assertEqual(s["cover_missing"], 0)
            self.assertEqual(s["oversize_unlisted"], 0)
            self.assertGreaterEqual(s["coverage_pct"], 99)
            self.assertLessEqual(s["overlap_max_pct"], 1.0, s["overlap_pair"])
            self.assertEqual(s["tiles"], 3)  # (1,1),(1,2),(1,3)
            self.assertEqual(s["border_tiles"], 2)  # (1,1) и (1,2) есть у всех, (1,3) — у germany
            line = R.check_line(work)
            self.assertRegex(line, r"^regions=\d+ total_gb=[\d.]+ overlap_max_pct=[\d.]+ coverage_pct=[\d.]+ "
                                   r"max_region_gb=[\d.]+ oversize_unlisted=0 cover_missing=0 tiles=3 border_tiles=2 overlap_listed=\d+ overlap_listed_max_pct=[\d.]+$")

    def test_safe_id(self):
        self.assertEqual(R.safe_id("us/georgia"), "us_georgia")


if __name__ == "__main__":
    unittest.main()
