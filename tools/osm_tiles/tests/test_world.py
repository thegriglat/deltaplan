"""Тесты оркестратора world.py: локальный HTTP-сервер с Range/If-Range, заглушка osmtiles (stub_osmtiles.py).
Покрыто: полный прогон, докачка после обрыва, падение pack, kill -9 посреди скачивания и pack, md5, нехватка места,
регионы вне списка (partial), status."""
import hashlib
import http.server
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
import world  # noqa: E402
import compare_runs  # noqa: E402

WORLD = os.path.join(os.path.dirname(HERE), "world.py")
STUB = os.path.join(HERE, "stub_osmtiles.py")

# регионы: a и b делят тайл (1, 0); c делит (2, 0) с b
COVER = {"a": [(0, 0), (1, 0), (0, 1)], "b": [(1, 0), (2, 0), (1, 1)], "c": [(2, 0), (3, 0), (3, 1)]}
BODY = {r: hashlib.sha256(r.encode()).digest() * 50000 for r in COVER}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        srv = self.server
        name = self.path.strip("/")
        srv.log.append((self.path, self.headers.get("Range"), self.headers.get("If-Range")))
        if name.endswith(".md5"):
            rid = name.split(".")[0]
            md5 = hashlib.md5(BODY[rid]).hexdigest()
            if rid in srv.bad_md5:
                md5 = "0" * 32
            body = ("%s  %s-latest.osm.pbf\n" % (md5, rid)).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        rid = name.split(".")[0]
        if rid not in BODY:
            self.send_error(404)
            return
        data, etag = BODY[rid], '"v1-%s"' % rid
        start, code = 0, 200
        rng = self.headers.get("Range")
        if rng and self.headers.get("If-Range", etag) == etag:
            start = int(re.match(r"bytes=(\d+)-", rng).group(1))
            if start >= len(data):
                self.send_error(416)
                return
            code = 206
        chunk = data[start:]
        self.send_response(code)
        self.send_header("ETag", etag)
        self.send_header("Content-Length", str(len(chunk)))
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(data) - 1, len(data)))
        self.end_headers()
        drop = srv.drop_once.pop(rid, None) if start == 0 else None
        try:
            step = 16384
            for k in range(0, len(chunk), step):
                if drop is not None and k >= drop:
                    self.wfile.flush()
                    self.connection.shutdown(2)       # обрыв посреди тела
                    return
                self.wfile.write(chunk[k:k + step])
                if srv.slow:
                    time.sleep(srv.slow)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


class Server:
    def __enter__(self):
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.httpd.log, self.httpd.drop_once, self.httpd.bad_md5, self.httpd.slow = [], {}, set(), 0
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        return self

    def __exit__(self, *a):
        self.httpd.shutdown()
        self.httpd.server_close()

    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.port


def make_work(work, base, ids=("a", "b", "c")):
    os.makedirs(os.path.join(work, "cover"))
    os.makedirs(os.path.join(work, "poly"))
    regs = []
    for r in COVER:           # cover всех трёх — всегда, как в настоящем плане
        txt = "".join("%d %d\n" % t for t in COVER[r])
        open(os.path.join(work, "cover", r + ".txt"), "w").write(txt)
        open(os.path.join(work, "poly", r + ".poly"), "w").write(txt)
        regs.append({"id": r, "index_id": r, "parent": None, "url": "%s/%s.osm.pbf" % (base, r),
                     "poly_url": "", "md5_url": "%s/%s.md5" % (base, r), "pbf_bytes": len(BODY[r]), "tiles": 3})
    json.dump({"schema": "osmtiles-regions/1", "regions": regs}, open(os.path.join(work, "regions.json"), "w"))


def run_world(work, out, regions="a,b,c", extra=(), env=None, wait=True, timeout=120):
    cmd = [sys.executable, WORLD, "run", "--work", work, "--out", out, "--regions", regions, "--osmtiles", STUB,
           "--keep-free-gb", "0"] + list(extra)
    e = dict(os.environ, WORLD_FAST_RETRY="1")
    e.update(env or {})
    if not wait:
        return subprocess.Popen(cmd, env=e, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    r = subprocess.run(cmd, env=e, capture_output=True, timeout=timeout)
    r.stdout, r.stderr = r.stdout.decode(), r.stderr.decode()
    return r


class WorldTest(unittest.TestCase):
    def setUp(self):
        os.chmod(STUB, 0o755)
        self.tmp = tempfile.mkdtemp(prefix="world_test_")
        self.srv = Server().__enter__()
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        self.addCleanup(lambda: self.srv.__exit__())

    def dirs(self, name):
        w, o = os.path.join(self.tmp, name, "work"), os.path.join(self.tmp, name, "out")
        os.makedirs(os.path.dirname(w), exist_ok=True)
        make_work(w, self.srv.base)
        return w, o

    def reference(self):
        w, o = self.dirs("ref")
        r = run_world(w, o)
        self.assertEqual(r.returncode, 0, r.stderr)
        return o

    def same(self, o1, o2):
        a, b = compare_runs.tile_hashes(o1), compare_runs.tile_hashes(o2)
        self.assertEqual(len(a), len(b))
        self.assertEqual(a, b)
        self.assertGreater(len(a), 5)

    # ---- основной путь
    def test_full_run(self):
        w, o = self.dirs("full")
        r = run_world(w, o)
        self.assertEqual(r.returncode, 0, r.stderr)
        tiles = compare_runs.tile_hashes(o)
        union = {t for v in COVER.values() for t in v}
        self.assertEqual(set(tiles), union)
        self.assertGreater(os.path.getsize(os.path.join(o, "v1", "manifest.pb")), 100)
        st = json.load(open(os.path.join(w, "state.json")))
        self.assertTrue(all(v["status"] == "done" for v in st["regions"].values()))
        # выгрузки и фрагменты удалены
        self.assertEqual(os.listdir(os.path.join(w, "dl")), [])
        left = [f for _d, _s, fs in os.walk(os.path.join(w, "frags")) for f in fs]
        self.assertEqual(left, [])
        self.assertEqual(len(open(os.path.join(w, "finalized.jsonl")).read().splitlines()), len(union))
        # склейка границы: тайл (1,0) собран из a и b
        body = open(os.path.join(o, "v1", "1", "0.dpt"), "rb").read()
        self.assertEqual(json.loads(body[7:])["sources"], ["a", "b"])
        ev = [json.loads(x)["event"] for x in open(os.path.join(w, "log.jsonl"))]
        self.assertIn("downloaded", ev)
        self.assertIn("manifest", ev)
        # sources.json для манифеста
        src = json.load(open(os.path.join(w, "sources.json")))
        self.assertEqual([s["region"] for s in src], ["a", "b", "c"])
        self.assertTrue(all(len(s["md5"]) == 32 and s["osm_timestamp"] == 1760000000 for s in src))

    def test_status(self):
        w, o = self.dirs("st")
        self.assertEqual(run_world(w, o).returncode, 0)
        r = subprocess.run([sys.executable, WORLD, "status", "--work", w], capture_output=True, text=True)
        self.assertIn("regions done 3/3", r.stdout)
        self.assertIn("тайлов 7", r.stdout)

    def test_progress_line_and_log_file(self):
        w, o = self.dirs("prog")
        lg = os.path.join(self.tmp, "p.log")
        r = run_world(w, o, extra=["--log", lg])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("\r", open(lg).read())
        w2, o2 = self.dirs("prog2")
        r = run_world(w2, o2, env={"WORLD_PROGRESS": "1"})
        self.assertRegex(r.stdout, r"\rрегион \d/3 \w · скачано [\d,]+/[\d,]+ ГБ · упаковано \d · тайлов \S+ \([\d,]+ ГБ\) · ETA")

    # ---- устойчивость
    def test_download_resume_range(self):
        ref = self.reference()
        self.srv.httpd.log.clear()
        self.srv.httpd.drop_once["b"] = 100000
        w, o = self.dirs("resume")
        r = run_world(w, o)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.same(ref, o)
        ranged = [x for x in self.srv.httpd.log if x[0].startswith("/b.osm") and x[1]]
        self.assertTrue(ranged, self.srv.httpd.log)
        self.assertEqual(ranged[0][2], '"v1-b"')       # If-Range по ETag

    def test_pack_dies_then_rerun(self):
        ref = self.reference()
        w, o = self.dirs("die")
        flag = os.path.join(self.tmp, "die.flag")
        r = run_world(w, o, env={"STUB_DIE_ONCE": flag})
        self.assertEqual(r.returncode, 1)
        self.assertIn("ОШИБКА упаковки", r.stderr)
        self.assertNotIn("manifest.pb", os.listdir(os.path.join(o, "v1")) if os.path.isdir(os.path.join(o, "v1")) else [])
        r = run_world(w, o, env={"STUB_DIE_ONCE": flag})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.same(ref, o)

    def wait_for(self, cond, timeout=30):
        t0 = time.time()
        while time.time() - t0 < timeout:
            if cond():
                return True
            time.sleep(0.05)
        return False

    def status_of(self, w, rid):
        try:
            return json.load(open(os.path.join(w, "state.json")))["regions"][rid]["status"]
        except (OSError, ValueError, KeyError):
            return None

    def test_kill_during_pack(self):
        ref = self.reference()
        w, o = self.dirs("killpack")
        p = run_world(w, o, env={"STUB_PACK_SLEEP": "3"}, wait=False)
        self.assertTrue(self.wait_for(lambda: self.status_of(w, "b") in ("downloading", "downloaded") or
                                      self.status_of(w, "a") == "packing"))
        self.assertTrue(self.wait_for(lambda: self.status_of(w, "a") == "packing"))
        p.send_signal(signal.SIGKILL)
        p.wait()
        time.sleep(0.5)
        r = run_world(w, o)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.same(ref, o)

    def test_kill_during_download(self):
        ref = self.reference()
        self.srv.httpd.slow = 0.01
        w, o = self.dirs("killdl")
        p = run_world(w, o, wait=False)
        part = os.path.join(w, "dl", "a.osm.pbf.part")
        self.assertTrue(self.wait_for(lambda: os.path.exists(part) and os.path.getsize(part) > 50000))
        p.send_signal(signal.SIGKILL)
        p.wait()
        self.srv.httpd.log.clear()
        self.srv.httpd.slow = 0
        r = run_world(w, o)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.same(ref, o)
        self.assertTrue(any(x[0].startswith("/a.osm") and x[1] for x in self.srv.httpd.log))

    def test_ctrl_c_clean_exit_and_continue(self):
        ref = self.reference()
        self.srv.httpd.slow = 0.01
        w, o = self.dirs("sigint")
        p = run_world(w, o, wait=False)
        part = os.path.join(w, "dl", "a.osm.pbf.part")
        self.assertTrue(self.wait_for(lambda: os.path.exists(part) and os.path.getsize(part) > 50000))
        p.send_signal(signal.SIGINT)
        out, err = p.communicate(timeout=30)
        self.assertEqual(p.returncode, 130, err)
        self.assertIn("повторите ту же команду run", err)
        self.srv.httpd.slow = 0
        r = run_world(w, o)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.same(ref, o)

    # ---- ошибки
    def test_md5_mismatch(self):
        self.srv.httpd.bad_md5.add("c")
        w, o = self.dirs("md5")
        r = run_world(w, o)
        self.assertEqual(r.returncode, 1)
        self.assertIn("md5 не сошёлся", r.stderr)
        st = json.load(open(os.path.join(w, "state.json")))["regions"]
        self.assertEqual(st["c"]["status"], "failed")
        self.assertEqual(st["a"]["status"], "done")
        self.assertEqual(sum(1 for x in self.srv.httpd.log if x[0].startswith("/c.osm")), 3)

    def test_not_found(self):
        w, o = self.dirs("nf")
        rj = json.load(open(os.path.join(w, "regions.json")))
        rj["regions"][2]["url"] = self.srv.base + "/nope.osm.pbf"
        json.dump(rj, open(os.path.join(w, "regions.json"), "w"))
        r = run_world(w, o)
        self.assertEqual(r.returncode, 1)
        self.assertIn("сервер ответил 404", r.stderr)

    def test_not_enough_space(self):
        w, o = self.dirs("space")
        r = run_world(w, o, extra=["--keep-free-gb", "1000000000"])
        self.assertEqual(r.returncode, 1)
        self.assertIn("мало места на диске", r.stderr)
        self.assertEqual(self.srv.httpd.log, [])           # до проверки места ничего не качалось

    def test_unknown_region(self):
        w, o = self.dirs("unk")
        r = run_world(w, o, regions="a,zzz")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("нет таких регионов", r.stderr)

    # ---- регионы вне списка
    def test_partial_regions(self):
        w, o = self.dirs("part")
        r = run_world(w, o, regions="a,b")
        self.assertEqual(r.returncode, 0, r.stderr)
        tiles = compare_runs.tile_hashes(o)
        self.assertEqual(set(tiles), set(COVER["a"]) | set(COVER["b"]))
        body = open(os.path.join(o, "v1", "2", "0.dpt"), "rb").read()      # (2,0): b и c; c вне списка
        self.assertEqual(json.loads(body[7:])["sources"], ["b"])
        ev = [json.loads(x) for x in open(os.path.join(w, "log.jsonl"))]
        self.assertTrue(any(e.get("partial_outside") == ["c"] for e in ev))
        self.assertFalse(any(x[0].startswith("/c.") for x in self.srv.httpd.log))

    def test_parallel_downloads_limit(self):
        # не больше двух выгрузок на диске одновременно
        self.srv.httpd.slow = 0.0
        w, o = self.dirs("two")
        p = run_world(w, o, env={"STUB_PACK_SLEEP": "1"}, wait=False)
        mx = 0
        while p.poll() is None:
            d = os.path.join(w, "dl")
            if os.path.isdir(d):
                mx = max(mx, len([f for f in os.listdir(d)]))
            time.sleep(0.02)
        self.assertEqual(p.returncode, 0, p.stderr.read())
        self.assertLessEqual(mx, 2)

    def test_second_run_is_noop(self):
        w, o = self.dirs("noop")
        self.assertEqual(run_world(w, o).returncode, 0)
        self.srv.httpd.log.clear()
        self.assertEqual(run_world(w, o).returncode, 0)
        self.assertEqual(self.srv.httpd.log, [])


class UnitTest(unittest.TestCase):
    def test_formats(self):
        self.assertEqual(world.fmt_gb(1.5e9), "1,50")
        self.assertEqual(world.fmt_gb(12.34e9), "12,3")
        self.assertEqual(world.fmt_eta(3 * 3600 + 12 * 60), "3 ч 12 мин")
        self.assertEqual(world.fmt_eta(None), "?")
        self.assertEqual(world.fmt_n(51234), "51 234")


if __name__ == "__main__":
    unittest.main()
