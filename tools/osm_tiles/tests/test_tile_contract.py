import json
import math
import unittest

import _env  # noqa: F401  (путь и zstd)
from _env import GOLDEN
import read_tile

DLAT = 0.18
R = 6371008.8
M = math.pi * R / 180.0


def band(j):
    kx = M * math.cos(math.radians((j + 0.5) * DLAT))
    n = max(1, math.floor(360 * kx / 20000))
    return n, 360.0 / n, kx


def project(lat, lon):
    """Независимая от Rust реализация O1 по тексту контракта."""
    if not -180.0 <= lon < 180.0:
        lon = (lon + 180.0) % 360.0 - 180.0
    j = max(-500, min(499, math.floor(max(-90.0, min(90.0, lat)) / DLAT)))
    n, dlon, kx = band(j)
    i = max(0, min(n - 1, math.floor((lon + 180.0) / dlon)))
    return j, i, (lon - (-180.0 + i * dlon)) * kx, (lat - j * DLAT) * M


class SampleDecode(unittest.TestCase):
    def check(self, name):
        data = (GOLDEN / (name + ".dpt")).read_bytes()
        want = json.loads((GOLDEN / (name + ".json")).read_text())
        self.assertEqual(read_tile.read_tile(data), want)

    def test_sample(self):
        self.check("sample_v1")

    def test_fragment_sample(self):
        self.check("sample_frag_v1")

    def test_sample_content(self):
        d = read_tile.read_tile((GOLDEN / "sample_v1.dpt").read_bytes())
        self.assertEqual(len(d["streams"]), 14)
        self.assertEqual([s["kind"] for s in d["streams"]], sorted((s["kind"] for s in d["streams"]),
                         key=list(read_tile.KINDS.values()).index))
        names = next(s for s in d["streams"] if s["kind"] == "names")["objects"]
        self.assertIn("Триглав", names)
        self.assertEqual(d["n"], band(d["j"])[0])

    def test_bad_magic(self):
        with self.assertRaises(ValueError):
            read_tile.read_tile(b"XXXX" + b"\0" * 20)


class GridGolden(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.g = json.loads((GOLDEN / "grid_golden.json").read_text())

    def test_bands(self):
        self.assertEqual(len(self.g["bands"]), 1000)
        for b in self.g["bands"]:
            n, dlon, kx = band(b["j"])
            self.assertEqual(n, b["n"], b["j"])
            self.assertAlmostEqual(dlon, b["dlon"], places=12)
            self.assertAlmostEqual(kx, b["kx"], places=6)

    def test_points(self):
        self.assertGreaterEqual(len(self.g["points"]), 300)
        for p in self.g["points"]:
            j, i, x, y = project(p["lat"], p["lon"])
            self.assertEqual((j, i), (p["j"], p["i"]), p)
            self.assertAlmostEqual(x, p["x"], delta=1e-6)
            self.assertAlmostEqual(y, p["y"], delta=1e-6)


if __name__ == "__main__":
    unittest.main()
