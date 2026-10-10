import json
import sys
import contextlib
import io
import tempfile
import unittest
from pathlib import Path

D = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(D))
import estimate_planet as ep  # noqa: E402
import ref_to_stats  # noqa: E402

TI = json.loads((ep.DEFAULT_RES / "taginfo_counts.json").read_text())


class Estimate(unittest.TestCase):
    def test_world_counts_match_report20(self):
        rep = json.loads((ep.DEFAULT_RES / "report20.json").read_text())["world_counts"]
        w = ep.world_counts(TI, 1.0)
        self.assertEqual(w["roads_major"], rep["roads_major"])
        self.assertEqual(w["roads_minor"], rep["roads_minor"])
        self.assertEqual(w["_buildings_all"], rep["bldg"])
        for k in ("track", "powerline", "aerialway", "aeroway", "vertical", "rail", "peak", "pass", "river",
                  "canal"):
            self.assertEqual(w[k], rep[k], k)
        self.assertEqual(w["power_tower"], rep["tower"])

    def test_price_times_world(self):
        # один поток: 1000 объектов, 50000 Б -> 50 Б/объект
        st = {"n_tiles": 1, "totals": {"track": {"count": 1000, "zstd": 50000}}}
        e = ep.estimate_place(st, TI, 0.8)
        self.assertAlmostEqual(e["world_B"]["track"], 50 * ep.world_counts(TI, 0.8)["track"], delta=1)
        self.assertEqual(e["world_GB"], round(e["world_B"]["track"] / 1e9, 3))
        self.assertIn("buildings", e["streams_without_objects"])

    def test_roads_split(self):
        st = {"n_tiles": 1, "totals": {"roads": {"count": 100, "zstd": 1000}, "roads_major": {"count": 20, "zstd": 400}}}
        e = ep.estimate_place(st, TI, 0.8)
        w = ep.world_counts(TI, 0.8)
        self.assertAlmostEqual(e["world_B"]["roads"], 20 * w["roads_major"] + 7.5 * w["roads_minor"], delta=1)

    def test_names_scaled_by_fraction(self):
        st = {"n_tiles": 1, "totals": {"peak": {"count": 10, "zstd": 1}, "pass": {"count": 10, "zstd": 1},
                                       "names": {"count": 10, "zstd": 100}}}
        e = ep.estimate_place(st, TI, 0.8)
        w = ep.world_counts(TI, 0.8)
        self.assertAlmostEqual(e["world_B"]["names"], 10 * 0.5 * w["names"], delta=1)

    def test_cli_range(self):
        with tempfile.TemporaryDirectory() as d:
            ps = []
            for ref in ("slovenia", "almaty"):
                p = Path(d) / f"{ref}.json"
                p.write_text(json.dumps(ref_to_stats.to_o6(ref_to_stats.load_ref(ref)[0], place=ref)))
                ps.append(str(p))
            out = Path(d) / "o.json"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(ep.main(ps + ["--out", str(out)]), 0)
            r = json.loads(out.read_text())
            self.assertLess(r["planet_GB"][0], r["planet_GB"][1])
            self.assertGreater(r["planet_GB"][0], 1)
            self.assertLess(r["planet_GB"][1], 30)


if __name__ == "__main__":
    unittest.main()
