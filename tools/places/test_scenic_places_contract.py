"""Контрактный тест SCP-К1 (docs/contracts/scenic-places.md): формат файлов красивых мест, без сети и Godot.

Проверяет тестовый файл, все tools/places/scenic/*.json и data/places/scenic_places.json (если есть).
Запуск: python3 tools/places/test_scenic_places_contract.py
"""
import glob, json, math, os, re, unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIXTURE = os.path.join(ROOT, "tests/ui/fixtures/scenic_places_test.json")
REGIONS = sorted(glob.glob(os.path.join(ROOT, "tools/places/scenic/*.json")))
CATALOG = os.path.join(ROOT, "data/places/scenic_places.json")
KINDS = {"mountain", "canyon", "lake", "coast", "volcano", "glacier", "valley", "fjord", "desert", "island"}
FIELDS = {"id", "country", "name_en", "name_ru", "kind", "lat", "lon", "heading_deg", "agl_m",
          "view_lat", "view_lon", "why_en", "why_ru"}


def dist_bearing(lat1, lon1, lat2, lon2):
    """Расстояние, м, и пеленг, градусы от севера по часовой (сфера R = 6371 км)."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2 - lon1)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    d = 2 * 6371000.0 * math.asin(math.sqrt(a))
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return d, math.degrees(math.atan2(y, x)) % 360.0


def check_file(tc, path, counts):
    with open(path, encoding="utf-8") as f:
        raw = f.read()
    d = json.loads(raw)
    tc.assertEqual(d.get("format"), "deltaplan.scenic_places", path)
    tc.assertEqual(d.get("version"), 1, path)
    tc.assertEqual(set(d), {"format", "version", "countries", "places"}, path)
    countries, places = d["countries"], d["places"]
    tc.assertTrue(places, path + ": places пуст")
    for code, n in countries.items():
        tc.assertRegex(code, r"^[A-Z]{2}$")
        tc.assertTrue(n.get("en") and n.get("ru"), "%s: %s без en/ru" % (path, code))
    used = set()
    ids = []
    for p in places:
        pid = p.get("id", "?")
        tc.assertEqual(set(p), FIELDS, "%s: %s — поля" % (path, pid))
        tc.assertRegex(pid, r"^[a-z]{2}/[a-z0-9-]+$")
        tc.assertIn(p["country"], countries, pid)
        tc.assertEqual(pid[:2], p["country"].lower(), pid + ": префикс id не код страны")
        used.add(p["country"])
        for k in ("name_en", "name_ru"):
            tc.assertTrue(0 < len(p[k]) <= 60, "%s: %s" % (pid, k))
        for k in ("why_en", "why_ru"):
            tc.assertTrue(0 < len(p[k]) <= 140, "%s: %s" % (pid, k))
        tc.assertIn(p["kind"], KINDS, pid)
        tc.assertTrue(-90 <= p["lat"] <= 90 and -180 <= p["lon"] <= 180, pid)
        tc.assertTrue(-90 <= p["view_lat"] <= 90 and -180 <= p["view_lon"] <= 180, pid)
        tc.assertTrue(0 <= p["heading_deg"] < 360, pid + ": heading_deg")
        tc.assertTrue(60 <= p["agl_m"] <= 1000, pid + ": agl_m (ASM-К1 v2: 60…1000)")
        dm, brg = dist_bearing(p["lat"], p["lon"], p["view_lat"], p["view_lon"])
        tc.assertLessEqual(dm, 15000.0, pid + ": вид дальше 15 км")
        dh = abs((brg - p["heading_deg"] + 180.0) % 360.0 - 180.0)
        tc.assertLessEqual(dh, 30.0, pid + ": пеленг на вид vs курс")
        ids.append(pid)
        counts[p["country"]] = counts.get(p["country"], 0) + 1
    tc.assertEqual(set(countries), used, path + ": лишние коды в countries")
    tc.assertEqual(ids, sorted(ids), path + ": места не по id")
    tc.assertEqual(list(countries), sorted(countries), path + ": countries не по алфавиту")
    tc.assertEqual(raw, json.dumps(d, ensure_ascii=False, indent=1) + "\n", path + ": не детерминированная запись")
    return ids


class ScenicPlacesContract(unittest.TestCase):
    def test_fixture(self):
        self.assertTrue(os.path.exists(FIXTURE))
        check_file(self, FIXTURE, {})

    def test_regions(self):
        counts, seen = {}, set()
        for path in REGIONS:
            for pid in check_file(self, path, counts):
                self.assertNotIn(pid, seen, pid + ": id повторяется")
                seen.add(pid)
        for code, n in counts.items():
            self.assertTrue(5 <= n <= 10, "%s: %d мест (нужно 5–10)" % (code, n))

    def test_catalog(self):
        if not os.path.exists(CATALOG):
            self.skipTest("каталога ещё нет")
        counts = {}
        check_file(self, CATALOG, counts)
        for code, n in counts.items():
            self.assertTrue(5 <= n <= 10, "%s: %d мест (нужно 5–10)" % (code, n))


if __name__ == "__main__":
    unittest.main()
