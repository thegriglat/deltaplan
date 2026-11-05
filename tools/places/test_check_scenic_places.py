"""Тест check_scenic_places без сети: синтетический рельеф вместо Terrarium."""
import math, os, sys, unittest

sys.path.insert(0, os.path.dirname(__file__))
import check_scenic_places as c

LAT, LON = 46.0, 8.0


def place(**kw):
    p = {"id": "ch/test", "country": "CH", "name_en": "T", "name_ru": "Т", "kind": "mountain",
         "lat": LAT, "lon": LON, "heading_deg": 0.0, "agl_m": 900, "view_lat": LAT + 0.07, "view_lon": LON,
         "why_en": "x", "why_ru": "х"}
    p.update(kw)
    return p


def bumpy(la, lo):  # холм у вида
    return 1000.0 + 400.0 * math.exp(-(((la - (LAT + 0.07)) * 111000) ** 2) / 2e6)


class T(unittest.TestCase):
    def test_ok(self):
        ok, txt, st = c.check_place(place(), bumpy)
        self.assertTrue(ok, txt)
        self.assertGreater(st["relief"], 100)

    def test_flat_no_relief(self):
        ok, txt, _ = c.check_place(place(), lambda a, b: 500.0)
        self.assertFalse(ok)
        self.assertIn("перепад", txt)

    def test_wall(self):
        wall = lambda la, lo: bumpy(la, lo) + (1500.0 if la > LAT + 0.02 else 0.0)  # ≈2.2 км от старта
        ok, txt, st = c.check_place(place(), wall)
        self.assertFalse(ok)
        self.assertIn("запас", txt)
        self.assertLess(st["margin"], 0)

    def test_bearing_and_distance(self):
        ok, txt, _ = c.check_place(place(heading_deg=90.0), bumpy)
        self.assertFalse(ok)
        self.assertIn("пеленг", txt)
        ok, txt, _ = c.check_place(place(view_lat=LAT + 0.2), bumpy)
        self.assertFalse(ok)
        self.assertIn("дальше", txt)

    def test_nodata(self):
        ok, txt, _ = c.check_place(place(), lambda a, b: float("nan"))
        self.assertFalse(ok)

    def test_png(self):
        import zlib, struct
        w = 2
        rows = b"".join(b"\x00" + bytes([128, 5, 0] * w) for _ in range(2))
        def ch(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
        png = b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, 2, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(rows)) + ch(b"IEND", b"")
        a = c.read_png_rgb(png)
        self.assertEqual(a[0, 0].tolist(), [128, 5, 0])

    def test_summary_format(self):
        import io, json, tempfile, contextlib
        d = {"format": "deltaplan.scenic_places", "version": 1, "countries": {"CH": {"en": "S", "ru": "Ш"}}, "places": [place()]}
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
            json.dump(d, f)
        old = c.elevation
        c.elevation = bumpy
        orig = c.check_place
        c.check_place = lambda p, elev=bumpy: orig(p, bumpy)
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                c.main([f.name])
        finally:
            c.elevation, c.check_place = old, orig
        last = buf.getvalue().strip().splitlines()[-1]
        self.assertRegex(last, r"^checked \d+, failed \d+$")


if __name__ == "__main__":
    unittest.main()
