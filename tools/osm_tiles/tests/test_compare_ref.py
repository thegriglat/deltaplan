import json
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

D = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(D))
import compare_ref  # noqa: E402
import ref_to_stats  # noqa: E402


def stats(ref, perturb=()):
    t, _ = ref_to_stats.load_ref(ref)
    for p in perturb:
        ref_to_stats.perturb(t, p)
    return ref_to_stats.to_o6(t, place=ref)


def fails(tb):
    return [r["metric"] for r in tb.rows if not r["ok"]]


class CompareRef(unittest.TestCase):
    def test_self_pass(self):
        for ref in ("slovenia", "almaty"):
            self.assertEqual(fails(compare_ref.compare(stats(ref), ref)), [])

    def test_buildings_2pct_fails(self):
        f = fails(compare_ref.compare(stats("slovenia", ["buildings:count:1.02"]), "slovenia"))
        self.assertTrue(any(m.startswith("buildings: число") for m in f))

    def test_buildings_within_tolerance(self):
        self.assertEqual(fails(compare_ref.compare(stats("slovenia", ["buildings:count:1.004"]), "slovenia")), [])

    def test_zstd_tolerance_edges(self):
        self.assertEqual(fails(compare_ref.compare(stats("slovenia", ["roads:zstd:1.04"]), "slovenia")), [])
        self.assertTrue(fails(compare_ref.compare(stats("slovenia", ["roads:zstd:1.06"]), "slovenia")))

    def test_small_stream_abs_tolerance(self):
        # aeroway = 80 объектов: ±max(2, 3 %) = 2,4 -> +2 проходит, +4 нет
        t, _ = ref_to_stats.load_ref("slovenia")
        base = ref_to_stats.to_o6(t)
        k = next(k for k in sorted(base["tiles"]) if "aeroway" in base["tiles"][k]["streams"])
        ok = json.loads(json.dumps(base))
        ok["tiles"][k]["streams"]["aeroway"]["count"] += 2
        self.assertEqual([m for m in fails(compare_ref.compare(ok, "slovenia")) if "aeroway: число" in m], [])
        bad = json.loads(json.dumps(base))
        bad["tiles"][k]["streams"]["aeroway"]["count"] += 4
        # k может быть не inside; ищем inside-тайл
        rt, ins = ref_to_stats.load_ref("slovenia")
        k2 = next(k for k in sorted(rt) if ins[k])
        bad["tiles"][k2]["streams"]["aeroway"]["count"] += 4
        self.assertTrue([m for m in fails(compare_ref.compare(bad, "slovenia")) if "aeroway: число" in m])

    def test_missing_tile(self):
        s = stats("slovenia")
        rt, ins = ref_to_stats.load_ref("slovenia")
        k = next(k for k in sorted(rt) if ins[k] and rt[k]["roads"]["count"])
        del s["tiles"][k]
        self.assertTrue(any("без наших" in m for m in fails(compare_ref.compare(s, "slovenia"))))

    def test_cover_extra_and_outside(self):
        s = stats("slovenia")
        rt, ins = ref_to_stats.load_ref("slovenia")
        out = next(k for k in sorted(rt) if not ins[k])
        cover = {k for k in rt if ins[k]}
        # тайл вне cover, нет у нас — не ошибка
        s2 = json.loads(json.dumps(s))
        s2["tiles"].pop(out, None)
        self.assertEqual(fails(compare_ref.compare(s2, "slovenia", cover)), [])
        # наш тайл из cover вне прямоугольника тайлов эталона — не судится
        s3 = json.loads(json.dumps(s))
        s3["tiles"]["1,1"] = {"file_bytes": 1, "streams": {}}
        self.assertEqual(fails(compare_ref.compare(s3, "slovenia", cover | {"1,1"})), [])
        # лишний наш тайл из cover внутри прямоугольника, которого нет в эталоне, — ошибка
        k = next(k for k in sorted(rt) if ins[k])
        rt2 = {kk: v for kk, v in rt.items() if kk != k}
        with mock.patch.object(compare_ref, "load_ref", return_value=(rt2, ins)):
            f = fails(compare_ref.compare(s, "slovenia", cover))
        self.assertTrue(any("нет в эталоне" in m for m in f), f)

    def test_cover_limited_to_ref_rect(self):
        # Алматы: cover всей страны — наши тайлы вне окна эталона не судятся, внутри окна — судятся
        s = stats("almaty")
        rt, _ = ref_to_stats.load_ref("almaty")
        far = "200,900"
        s["tiles"][far] = {"file_bytes": 1, "streams": {}}
        cover = set(rt) | {far}
        self.assertEqual(fails(compare_ref.compare(s, "almaty", cover)), [])
        s2 = json.loads(json.dumps(s))
        k = next(k for k in sorted(rt) if rt[k]["roads"]["count"])
        del s2["tiles"][k]
        self.assertTrue(any("без наших" in m for m in fails(compare_ref.compare(s2, "almaty", cover))))

    def test_file_vs_streams_tolerance(self):
        s = stats("slovenia")
        sz = sum(v["zstd"] for v in s["totals"].values())
        s["file_bytes_total"] = int(sz * 1.045)
        self.assertEqual(fails(compare_ref.compare(s, "slovenia")), [])
        s["file_bytes_total"] = int(sz * 1.055)
        self.assertTrue(any("итоговые файлы" in m for m in fails(compare_ref.compare(s, "slovenia"))))

    def test_cli_codes(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "s.json"
            p.write_text(json.dumps(stats("almaty")))
            r = subprocess.run([sys.executable, str(D / "compare_ref.py"), str(p), "--ref", "almaty"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout)
            p.write_text(json.dumps(stats("almaty", ["track:len_km:1.01"])))
            r = subprocess.run([sys.executable, str(D / "compare_ref.py"), str(p), "--ref", "almaty"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)


if __name__ == "__main__":
    unittest.main()
