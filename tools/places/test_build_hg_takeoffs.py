import os, sys, unittest
sys.path.insert(0, os.path.dirname(__file__))
from build_hg_takeoffs import parse_orientation as p


class T(unittest.TestCase):
    def test_cases(self):
        self.assertEqual(p("S-SW"), ["S", "SSW", "SW"])
        self.assertEqual(p("SSW-NNW"), ["SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"])
        self.assertEqual(p("NNW-SSW"), ["NNW", "NW", "WNW", "W", "WSW", "SW", "SSW"])
        self.assertEqual(p("SO-SW"), ["SE", "SSE", "S", "SSW", "SW"])
        self.assertEqual(p("NO"), ["NE"])
        self.assertEqual(p("ONO"), ["ENE"])
        self.assertEqual(p("W-O"), [])
        self.assertEqual(p("O"), [])
        self.assertEqual(p("S;"), ["S"])
        self.assertEqual(p("225"), ["SW"])
        self.assertEqual(p("SE,S,SW"), ["SE", "S", "SW"])
        self.assertEqual(p("n;ne;n"), ["N", "NE"])
        self.assertEqual(p("N-S"), ["N", "S"])
        self.assertEqual(p("350"), ["N"])
        self.assertEqual(p("S foo"), ["S"])
        self.assertEqual(p(None), [])

    def test_dropped(self):
        d = []
        p("W-O;S;xyz", d)
        self.assertEqual(d, ["W-O", "XYZ"])


if __name__ == "__main__":
    unittest.main()
