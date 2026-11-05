"""Тест сборки каталога красивых мест: на временных файлах регионов, без сети."""
import json, os, sys, tempfile, unittest

sys.path.insert(0, os.path.dirname(__file__))
import build_scenic_places as B


def place(pid, country):
    return {"id": pid, "country": country, "name_en": "N", "name_ru": "Н", "kind": "lake", "lat": 1.0, "lon": 2.0,
            "heading_deg": 10.0, "agl_m": 100, "view_lat": 1.01, "view_lon": 2.0, "why_en": "w", "why_ru": "п"}


def region(path, countries, places):
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"format": "deltaplan.scenic_places", "version": 1, "countries": countries, "places": places}, f, ensure_ascii=False)


class Test(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.src = os.path.join(self.d.name, "src")
        os.mkdir(self.src)
        region(os.path.join(self.src, "a.json"), {"RU": {"en": "Russia", "ru": "Россия"}, "AR": {"en": "Argentina", "ru": "Аргентина"}},
               [place("ru/b", "RU"), place("ar/z", "AR")])
        region(os.path.join(self.src, "b.json"), {"AR": {"en": "Argentina", "ru": "Аргентина"}, "CA": {"en": "Canada", "ru": "Канада"}},
               [place("ca/m", "CA"), place("ar/a", "AR")])
        self.out = os.path.join(self.d.name, "out", "cat.json")

    def tearDown(self):
        self.d.cleanup()

    def test_merge_sorted(self):
        self.assertEqual(B.main(["--src", self.src, "--out", self.out]), 0)
        doc = json.load(open(self.out, encoding="utf-8"))
        self.assertEqual([p["id"] for p in doc["places"]], ["ar/a", "ar/z", "ca/m", "ru/b"])
        self.assertEqual(list(doc["countries"]), ["AR", "CA", "RU"])
        self.assertFalse(os.path.exists(self.out + ".tmp"))

    def test_duplicate_id(self):
        region(os.path.join(self.src, "c.json"), {"AR": {"en": "Argentina", "ru": "Аргентина"}}, [place("ar/a", "AR")])
        self.assertEqual(B.main(["--src", self.src, "--out", self.out]), 1)
        self.assertFalse(os.path.exists(self.out))

    def test_deterministic_bytes(self):
        B.main(["--src", self.src, "--out", self.out])
        a = open(self.out, "rb").read()
        B.main(["--src", self.src, "--out", self.out])
        self.assertEqual(a, open(self.out, "rb").read())
        self.assertTrue(a.endswith(b"}\n"))
        self.assertIn("Россия".encode(), a)


if __name__ == "__main__":
    unittest.main()
