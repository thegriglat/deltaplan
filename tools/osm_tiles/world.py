#!/usr/bin/env python3
"""OT-6: оркестратор мировой сборки тайлов OSM (контракт O8).

  world.py run    --work <dir> --out <корень> [--regions id1,id2 | --all] [--max-region-gb 2.0]
                  [--keep-free-gb 20] [--threads N] [--osmtiles <бинарь>] [--seed-from <dir OT-5>] [--log <файл>]
  world.py status --work <dir>
  world.py plan   --work <dir> [--max-region-gb 2.0] [--regions ...] [--osmtiles <бинарь>] [--seed-from <dir>]

Что делает `run`: качает выгрузки Geofabrik по одной (Range/If-Range, md5), упаковывает `osmtiles pack`, склеивает
готовые тайлы `osmtiles finalize`, удаляет выгрузки и фрагменты, в конце строит манифест. Пока пакуется текущий
регион, качается следующий (на диске не больше двух выгрузок). Ctrl-C — чистый выход; повторный `run` с тем же
--work продолжает с места остановки. Только stdlib.

Раскладка в --work: regions.json, cover/, poly/ (OT-5); state.json, finalized.jsonl, log.jsonl; dl/ (выгрузки),
frags/<j>/<i>/<регион>.frag (фрагменты O4), tmp/, reports/<регион>.pack.json.
"""
import argparse
import hashlib
import json
import math
import os
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import regions as R  # noqa: E402

try:
    import fcntl
except ImportError:  # Windows
    fcntl = None

GB = 1e9
UA = R.USER_AGENT
CHUNK = 1 << 20
NET_TRIES = 6                  # подряд ошибок сети на один регион до «failed»
MD5_TRIES = 3
FINALIZE_BATCH = 2000          # тайлов в одном вызове finalize (гранулярность продолжения)
SAVE_EVERY_S = 5.0
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BIN = os.path.join(HERE, "packer", "target", "release", "osmtiles")
STATUSES = ["planned", "downloading", "downloaded", "split", "packing", "packed", "done", "failed"]


# ------------------------------------------------------------------ утилиты

def fmt_gb(b):
    return ("%.2f" % (b / GB)).replace(".", ",") if b < 10 * GB else ("%.1f" % (b / GB)).replace(".", ",")


def fmt_n(n):
    return "{:,}".format(int(n)).replace(",", " ")


def fmt_eta(s):
    if s is None or s != s or s == math.inf:
        return "?"
    s = int(s)
    if s < 60:
        return "%d с" % s
    m = s // 60
    if m < 60:
        return "%d мин" % m
    return "%d ч %02d мин" % (m // 60, m % 60)


def say(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def read_jsonl(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        out.append(json.loads(line))
                    except ValueError:
                        pass          # оборванная последняя строка после kill -9
    except FileNotFoundError:
        pass
    return out


def dir_bytes(path):
    total = 0
    stack = [path]
    while stack:
        try:
            with os.scandir(stack.pop()) as it:
                for e in it:
                    try:
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        else:
                            total += e.stat(follow_symlinks=False).st_size
                    except OSError:
                        pass
        except OSError:
            pass
    return total


def free_bytes(path):
    return shutil.disk_usage(path).free


class Stop(Exception):
    pass


# ------------------------------------------------------------------ рабочий каталог и состояние

class Work:
    def __init__(self, work):
        self.dir = os.path.abspath(work)
        self.state_path = os.path.join(self.dir, "state.json")
        self.fin_path = os.path.join(self.dir, "finalized.jsonl")
        self.log_path = os.path.join(self.dir, "log.jsonl")
        self.lock = threading.RLock()
        self.state = None
        self._saved = 0.0

    def p(self, *a):
        return os.path.join(self.dir, *a)

    def load_state(self):
        self.state = R.load_json(self.state_path) or {"schema": "osmtiles-state/1", "out": "", "regions": {}}
        return self.state

    def save(self, force=True):
        with self.lock:
            now = time.time()
            if not force and now - self._saved < SAVE_EVERY_S:
                return
            self._saved = now
            R.atomic_write(self.state_path, json.dumps(self.state, ensure_ascii=False, indent=1))

    def reg(self, rid):
        return self.state["regions"][rid]

    def set(self, rid, **kw):
        with self.lock:
            self.state["regions"][rid].update(kw)
            self.save()

    def event(self, event, **kw):
        rec = {"t": round(time.time(), 3), "event": event}
        rec.update({k: v for k, v in kw.items() if v is not None})
        with self.lock:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")


# ------------------------------------------------------------------ набор регионов и покрытие

def seed_work(work, seed):
    """Копирует кеш OT-5 (индекс, HEAD-размеры, regions.json, .poly, cover), если в --work ещё нет regions.json."""
    if os.path.exists(os.path.join(work, "regions.json")) or not seed:
        return
    os.makedirs(work, exist_ok=True)
    say("беру готовый набор регионов из " + seed)
    for name in ("index-v1.json", "heads.json", "regions.json"):
        if os.path.exists(os.path.join(seed, name)):
            shutil.copy2(os.path.join(seed, name), os.path.join(work, name))
    for d in ("poly", "cover"):
        if os.path.isdir(os.path.join(seed, d)):
            shutil.copytree(os.path.join(seed, d), os.path.join(work, d), dirs_exist_ok=True)


def ensure_plan(args, ids=None):
    """regions.json + cover/poly для нужных регионов; недостающее достраивает regions.py (набор заморожен)."""
    work = args.work
    seed_work(work, getattr(args, "seed_from", None))
    rj = R.load_json(os.path.join(work, "regions.json"))
    need = rj is None
    if rj is not None:
        for r in rj["regions"]:
            if ids is not None and r["id"] not in ids:
                continue
            if not os.path.exists(os.path.join(work, "cover", r["id"] + ".txt")) or \
               not os.path.exists(os.path.join(work, "poly", r["id"] + ".poly")):
                need = True
                break
    if need:
        if not os.path.exists(args.osmtiles):
            sys.exit("нет упаковщика %s — соберите: cd tools/osm_tiles/packer && cargo build --release" % args.osmtiles)
        ns = argparse.Namespace(work=work, max_region_gb=args.max_region_gb, osmtiles=args.osmtiles,
                                recompute_cover=False, force=False)
        R.cmd_plan(ns)
        rj = R.load_json(os.path.join(work, "regions.json"))
    return rj


def poly_bbox(path):
    """(minlon, minlat, maxlon, maxlat) по .poly Osmosis (строки «lon lat»)."""
    xs, ys = [], []
    for line in open(path):
        p = line.split()
        if len(p) == 2:
            try:
                xs.append(float(p[0]))
                ys.append(float(p[1]))
            except ValueError:
                pass
    if not xs:
        raise RuntimeError("пустой .poly " + path)
    return [min(xs), min(ys), max(xs), max(ys)]


def rect_poly(name, bb):
    x0, y0, x1, y1 = bb
    pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)]
    return name + "\n1\n" + "".join("   %.7f   %.7f\n" % p for p in pts) + "END\nEND\n"


def expand_splits(args, w, state, regions):
    """O8 v2: регион с .pbf > --max-region-gb режется на k частей-прямоугольников по долготе (id `<id>__p<n>`).
    Возвращает список: родитель (скачивается), затем его части (ждут нарезки). Разбиение запоминается в state."""
    limit = args.max_region_gb * GB
    splits = state.setdefault("splits", {})
    out = []
    for r in regions:
        sp = splits.get(r["id"])
        if not sp and r["pbf_bytes"] > limit:
            k = math.ceil(r["pbf_bytes"] / limit)
            x0, y0, x1, y1 = poly_bbox(w.p("poly", r["id"] + ".poly"))
            edges = [x0 + (x1 - x0) * n / k for n in range(k)] + [x1]
            sp = splits[r["id"]] = {"parts": [{"id": "%s__p%d" % (r["id"], n + 1), "bbox": [edges[n], y0, edges[n + 1], y1]}
                                              for n in range(k)]}
            say("%s: %s ГБ > лимита %s ГБ — после скачивания режу на %d частей по долготе" % (
                r["id"], fmt_gb(r["pbf_bytes"]), fmt_gb(limit), k))
        if not sp:
            out.append(r)
            continue
        parent = dict(r, parts=[p["id"] for p in sp["parts"]])
        out.append(parent)
        pcov = set(R.read_cover(w.p("cover", r["id"] + ".txt")))
        for p in sp["parts"]:
            poly, cov = w.p("poly", p["id"] + ".poly"), w.p("cover", p["id"] + ".txt")
            if not os.path.exists(poly):
                R.atomic_write(poly, rect_poly(p["id"], p["bbox"]))
            if not os.path.exists(cov):
                if not os.path.exists(args.osmtiles):
                    sys.exit("нет упаковщика %s — соберите: cd tools/osm_tiles/packer && cargo build --release" % args.osmtiles)
                txt = R.run_cover(args.osmtiles, poly, cov + ".all")
                os.remove(cov + ".all")
                tiles = sorted(set(tuple(map(int, l.split()[:2])) for l in txt.splitlines() if l.strip()) & pcov)
                R.atomic_write(cov, "".join("%d %d\n" % t for t in tiles))
            out.append({"id": p["id"], "split_of": r["id"], "bbox": p["bbox"], "url": "", "md5_url": "", "poly_url": "",
                        "pbf_bytes": r["pbf_bytes"] // len(sp["parts"]), "tiles": None})
    R.atomic_write(w.state_path, json.dumps(state, ensure_ascii=False, indent=1))
    return out


def select_regions(rj, args):
    by_id = {r["id"]: r for r in rj["regions"]}
    if args.regions:
        want = [x.strip() for x in args.regions.split(",") if x.strip()]
        bad = [x for x in want if x not in by_id]
        if bad:
            near = [i for i in by_id if any(b in i or i in b for b in bad)][:8]
            sys.exit("нет таких регионов в наборе: %s%s" % (", ".join(bad), ("; похожие: " + ", ".join(near)) if near else ""))
        return [by_id[x] for x in want]
    if args.all:
        return list(rj["regions"])
    sys.exit("укажите --regions id1,id2 или --all")


def load_covers(w, rj):
    """cover региона {id: [(j, i)…]} и S(t) = {(j, i): [регионы]} по всем cover/*.txt набора."""
    cover, s = {}, {}
    for r in rj["regions"]:
        p = os.path.join(w.dir, "cover", r["id"] + ".txt")
        if not os.path.exists(p):
            continue
        tiles = sorted(set(R.read_cover(p)))
        cover[r["id"]] = tiles
        for t in tiles:
            s.setdefault(t, []).append(r["id"])
    return cover, s


# ------------------------------------------------------------------ скачивание

def fetch_md5(url):
    body = R.retry(lambda: R.http(url, timeout=60).read().decode("utf-8", "replace"))
    tok = body.split()
    if not tok or len(tok[0]) != 32:
        raise RuntimeError("странный ответ .md5: " + body[:80])
    return tok[0].lower()


def file_md5(path, stop):
    h = hashlib.md5()
    with open(path, "rb") as f:
        while True:
            b = f.read(CHUNK)
            if not b:
                break
            if stop.is_set():
                raise Stop()
            h.update(b)
    return h.hexdigest()


class Downloader(threading.Thread):
    """Один поток скачивания; регионы по очереди, не больше двух выгрузок на диске, место ≥ размер×3 + keep_free."""

    def __init__(self, ctx, regions):
        super().__init__(daemon=True)
        self.ctx, self.regions = ctx, regions
        self.finished = False
        self.fatal = None
        self.waiting = ""          # пояснение для строки прогресса
        self.rate_bytes = 0

    def run(self):
        try:
            for r in self.regions:
                if not r.get("split_of") and self.ctx.w.reg(r["id"])["status"] in ("planned", "downloading"):
                    self.one(r)
                    if self.ctx.stop.is_set():
                        break
        except Stop:
            pass
        except Exception as e:   # noqa: BLE001
            self.fatal = "%s: %s" % (type(e).__name__, e)
        finally:
            if self.fatal:
                self.ctx.stop.set()
            self.finished = True

    def slot_and_space(self, r):
        c = self.ctx
        need = int(r["pbf_bytes"] * 3 + c.keep_free)
        while not c.stop.is_set():
            on_disk = [i for i in self.regions if c.w.reg(i["id"])["status"] in ("downloaded", "packing")]
            free = free_bytes(c.w.dir)
            reg = c.w.reg(r["id"])
            have = reg["bytes_done"] if reg["status"] == "downloading" else 0
            if len(on_disk) < 2 and free + have >= need:
                self.waiting = ""
                return
            if len(on_disk) >= 2:
                self.waiting = "жду, пока упакуется выгрузка"
            elif not on_disk:
                self.fatal = ("мало места на диске: для %s нужно %s ГБ (выгрузка %s ГБ × 3 + запас --keep-free-gb %s ГБ), "
                              "свободно %s ГБ. Освободите место или уменьшите --keep-free-gb, затем повторите run." %
                              (r["id"], fmt_gb(need), fmt_gb(r["pbf_bytes"]), fmt_gb(c.keep_free), fmt_gb(free)))
                raise Stop()
            else:
                self.waiting = "жду места на диске (свободно %s ГБ, нужно %s ГБ)" % (fmt_gb(free), fmt_gb(need))
            c.stop.wait(1.0)
        raise Stop()

    def one(self, r):
        c, rid = self.ctx, r["id"]
        self.slot_and_space(r)
        os.makedirs(c.w.p("dl"), exist_ok=True)
        part = c.w.p("dl", rid + ".osm.pbf.part")
        final = c.w.p("dl", rid + ".osm.pbf")
        c.w.set(rid, status="downloading", error="")
        c.w.event("download_start", region=rid, bytes_done=os.path.getsize(part) if os.path.exists(part) else 0)
        t0 = time.time()
        for attempt in range(MD5_TRIES):
            try:
                self.fetch_file(r, part)
                want = c.w.reg(rid)["md5"] or fetch_md5(r["md5_url"])
            except Stop:
                raise
            except OSError as e:
                if getattr(e, "errno", None) == 28:     # ENOSPC
                    self.fatal = "закончилось место на диске при скачивании %s. Освободите место и повторите run." % rid
                    raise Stop()
                self.fail(rid, "сеть/диск: %s" % e)
                return
            except RuntimeError as e:
                self.fail(rid, str(e))
                return
            c.w.set(rid, md5=want)
            got = file_md5(part, c.stop)
            if got == want:
                os.replace(part, final)
                size = os.path.getsize(final)
                c.w.set(rid, status="downloaded", bytes_done=size)
                c.w.event("downloaded", region=rid, bytes=size, seconds=round(time.time() - t0, 2), md5=got)
                return
            say("%s: md5 не сошёлся (попытка %d/%d) — качаю заново" % (rid, attempt + 1, MD5_TRIES))
            c.w.event("md5_mismatch", region=rid, got=got, want=want)
            os.remove(part)
            c.w.set(rid, bytes_done=0, etag="", md5="", attempts=c.w.reg(rid)["attempts"] + 1)
        self.fail(rid, "md5 не сошёлся %d раза подряд" % MD5_TRIES)

    def fail(self, rid, msg):
        say("%s: ОШИБКА скачивания — %s (регион пропущен; повторный run попробует снова)" % (rid, msg))
        self.ctx.w.set(rid, status="failed", error=msg)
        self.ctx.w.event("failed", region=rid, step="download", error=msg)

    def fetch_file(self, r, part):
        """Докачивает файл в part до полного размера. RuntimeError — окончательная ошибка (404 и т. п.)."""
        c, rid = self.ctx, r["id"]
        errors = 0
        while True:
            if c.stop.is_set():
                raise Stop()
            have = os.path.getsize(part) if os.path.exists(part) else 0
            etag = c.w.reg(rid).get("etag", "")
            headers = {"User-Agent": UA}
            if have and etag:
                headers["Range"] = "bytes=%d-" % have
                headers["If-Range"] = etag
            try:
                resp = urllib.request.urlopen(urllib.request.Request(r["url"], headers=headers), timeout=30)
            except urllib.error.HTTPError as e:
                if e.code == 416 and have:          # просили за концом: файл уже целый (проверит md5)
                    return
                if e.code in (401, 403, 404, 410):
                    raise RuntimeError("сервер ответил %d для %s" % (e.code, r["url"]))
                errors = self.backoff(errors, "HTTP %d" % e.code)
                continue
            except (urllib.error.URLError, OSError, TimeoutError) as e:
                errors = self.backoff(errors, str(e))
                continue
            with resp:
                new_etag = resp.headers.get("ETag", "") or resp.headers.get("Last-Modified", "")
                if resp.status == 206:
                    cr = resp.headers.get("Content-Range", "")
                    try:
                        start = int(cr.split()[1].split("-")[0])
                        total = int(cr.rsplit("/", 1)[1])
                    except (IndexError, ValueError):
                        start, total = -1, 0
                    if start != have:
                        raise RuntimeError("сервер вернул не то место докачки (%s)" % cr)
                    mode = "ab"
                else:                                # 200: файл целиком (новый или сменился) — с нуля
                    have = 0
                    total = int(resp.headers.get("Content-Length") or 0)
                    mode = "wb"
                    c.w.set(rid, etag=new_etag)
                try:
                    with open(part, mode) as f:
                        got = have
                        while True:
                            if c.stop.is_set():
                                raise Stop()
                            b = resp.read1(CHUNK)
                            if not b:
                                break
                            f.write(b)
                            got += len(b)
                            self.rate_bytes += len(b)
                            c.w.state["regions"][rid]["bytes_done"] = got
                            c.w.save(force=False)
                except Stop:
                    raise
                except OSError as e:
                    if getattr(e, "errno", None) == 28:
                        raise
                    c.w.set(rid, bytes_done=os.path.getsize(part))
                    errors = self.backoff(errors, str(e))
                    continue
                except Exception as e:  # noqa: BLE001  (http.client.IncompleteRead и т. п.)
                    c.w.set(rid, bytes_done=os.path.getsize(part))
                    errors = self.backoff(errors, "%s: %s" % (type(e).__name__, e))
                    continue
            size = os.path.getsize(part)
            c.w.set(rid, bytes_done=size)
            if total and size < total:
                errors = self.backoff(errors, "обрыв на %d из %d байт" % (size, total))
                continue
            return

    def backoff(self, errors, why):
        errors += 1
        if errors >= NET_TRIES:
            raise RuntimeError("нет связи с сервером (%d ошибок подряд, последняя: %s)" % (errors, why))
        delay = min(2 ** errors, 60) if not os.environ.get("WORLD_FAST_RETRY") else 0.2
        self.waiting = "сеть: %s; повтор через %d с (%d/%d)" % (why[:60], delay, errors, NET_TRIES)
        say(self.waiting)
        self.ctx.stop.wait(delay)
        self.waiting = ""
        return errors


# ------------------------------------------------------------------ упаковка и склейка

def _pdeathsig():
    try:
        import ctypes
        ctypes.CDLL("libc.so.6").prctl(1, signal.SIGKILL)   # PR_SET_PDEATHSIG: ребёнок гибнет вместе с world.py
    except Exception:  # noqa: BLE001
        pass


class Ctx:
    def __init__(self, args, w, rj, regions):
        self.args, self.w, self.rj, self.regions = args, w, rj, regions
        self.ids = [r["id"] for r in regions]
        self.by_id = {r["id"]: r for r in regions if not r.get("parts")}
        self.stop = threading.Event()
        self.user_stop = False
        self.keep_free = args.keep_free_gb * GB
        self.cover, self.S = load_covers(w, rj)
        self.finalized = {}               # (j, i) -> запись
        self.tiles_bytes = 0
        self.dl = None
        self.pack_rate_bytes = 0
        self.pack_rate_sec = 0.0
        self.last_draw = 0.0
        self.last_disk = 0.0
        self.peak_disk = 0
        self.t_start = time.time()
        self.cur_region = None
        for r in regions:               # O8 v2: у разрезанного региона cover — объединение cover его частей
            if r.get("parts"):
                for t in self.cover.pop(r["id"], []):
                    self.S[t].remove(r["id"])
            if r.get("split_of"):
                tiles = sorted(set(R.read_cover(w.p("cover", r["id"] + ".txt"))))
                self.cover[r["id"]] = tiles
                for t in tiles:
                    self.S.setdefault(t, []).append(r["id"])
        self.prior = rates_from_log(w)
        for rec in read_jsonl(w.fin_path):
            self.finalized[(rec["j"], rec["i"])] = rec
        self.tiles_bytes = sum(r["bytes"] for r in self.finalized.values())

    def run_child(self, cmd):
        """Дочерний процесс; при stop завершается. Возвращает (код, stdout, stderr)."""
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             preexec_fn=_pdeathsig if sys.platform.startswith("linux") else None)
        out, err = [], []
        ts = [threading.Thread(target=lambda: out.append(p.stdout.read()), daemon=True),
              threading.Thread(target=lambda: err.append(p.stderr.read()), daemon=True)]
        for t in ts:
            t.start()
        while p.poll() is None:
            if self.stop.is_set():
                p.terminate()
                try:
                    p.wait(10)
                except subprocess.TimeoutExpired:
                    p.kill()
                break
            self.tick()
            time.sleep(0.3)
        p.wait()
        for t in ts:
            t.join(5)
        return p.returncode, "".join(out), "".join(err)

    # ---- прогресс
    def totals(self):
        tot = done = 0
        for r in self.regions:
            if r.get("split_of"):
                continue
            tot += r["pbf_bytes"]
            reg = self.w.reg(r["id"])
            done += r["pbf_bytes"] if reg["status"] in ("downloaded", "split", "packing", "packed", "done") else reg["bytes_done"]
        return tot, done

    def eta(self):
        tot, done = self.totals()
        dl_rate = self.prior["dl"]
        el = time.time() - self.t_start
        if self.dl and self.dl.rate_bytes and el > 3:
            dl_rate = self.dl.rate_bytes / el
        pk_rate = (self.pack_rate_bytes / self.pack_rate_sec) if self.pack_rate_sec else self.prior["pack"]
        to_pack = sum(r["pbf_bytes"] for r in self.regions
                      if not (r.get("split_of") and self.w.reg(r["id"])["status"] == "planned")
                      and self.w.reg(r["id"])["status"] in ("planned", "downloading", "downloaded", "packing"))
        t = []
        if tot - done > 0:
            if not dl_rate:
                return None
            t.append((tot - done) / dl_rate)
        if to_pack:
            if not pk_rate:
                return None
            t.append(to_pack / pk_rate)
        return max(t) if t else 0

    def line(self):
        n = len(self.regions)
        st = [self.w.reg(i)["status"] for i in self.ids]
        k = sum(1 for s in st if s in ("done", "packed")) + 1
        cur = self.cur_region or next((i for i, s in zip(self.ids, st) if s in ("downloading", "downloaded", "packing")), "-")
        tot, done = self.totals()
        packed = sum(1 for s in st if s in ("packed", "done"))
        line = "регион %d/%d %s · скачано %s/%s ГБ · упаковано %d · тайлов %s (%s ГБ) · ETA %s" % (
            min(k, n), n, cur, fmt_gb(done), fmt_gb(tot), packed, fmt_n(len(self.finalized)), fmt_gb(self.tiles_bytes),
            fmt_eta(self.eta()))
        if self.dl and self.dl.waiting:
            line += " · " + self.dl.waiting
        return line

    def tick(self):
        now = time.time()
        if now - self.last_disk > 10:
            self.last_disk = now
            d = sum(dir_bytes(self.w.p(x)) for x in ("dl", "frags", "tmp")) + dir_bytes(self.args.out)
            self.peak_disk = max(self.peak_disk, d)
        if now - self.last_draw < (30 if self.args.log else 0.5):
            return
        self.last_draw = now
        if self.args.log:
            with open(self.args.log, "a") as f:
                f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + self.line() + "\n")
        elif sys.stdout.isatty() or os.environ.get("WORLD_PROGRESS"):
            sys.stdout.write("\r" + self.line() + "\x1b[K")
            sys.stdout.flush()

    def newline(self):
        if not self.args.log and (sys.stdout.isatty() or os.environ.get("WORLD_PROGRESS")):
            sys.stdout.write("\n")
            sys.stdout.flush()

    # ---- конвейер
    def tiles_ready(self, rid):
        """Тайлы региона rid, готовые к склейке: все выбранные регионы S(t) в packed|done, ещё не склеены."""
        ready = []
        for t in self.cover.get(rid, []):
            if t in self.finalized:
                continue
            sel = [x for x in self.S[t] if x in self.by_id]
            if all(self.w.reg(x)["status"] in ("packed", "done") for x in sel):
                ready.append((t, sel))
        return ready

    def pack(self, r):
        rid, w = r["id"], self.w
        pbf = w.p("dl", rid + ".osm.pbf")
        fdir = w.p("frags")
        shutil.rmtree(w.p("tmp", rid), ignore_errors=True)       # перезапуск packing — с чистого листа
        for (j, i) in self.cover.get(rid, []):
            try:
                os.remove(os.path.join(fdir, str(j), str(i), rid + ".frag"))
            except OSError:
                pass
        os.makedirs(fdir, exist_ok=True)
        os.makedirs(w.p("tmp", rid), exist_ok=True)
        stale = os.path.join(fdir, rid + ".pack.json")
        if os.path.exists(stale):
            os.remove(stale)
        w.set(rid, status="packing", error="")
        w.event("pack_start", region=rid)
        self.cur_region = rid
        cmd = [self.args.osmtiles, "pack", "--input", pbf, "--region", rid, "--poly", w.p("poly", rid + ".poly"),
               "--frag-dir", fdir, "--tmp", w.p("tmp", rid)]
        if self.args.threads:
            cmd += ["--threads", str(self.args.threads)]
        t0 = time.time()
        rc, _out, err = self.run_child(cmd)
        sec = time.time() - t0
        if self.stop.is_set():
            return False
        self.cur_region = None
        if rc != 0:
            msg = "osmtiles pack: код %d: %s" % (rc, err.strip()[-300:])
            say("%s: ОШИБКА упаковки — %s" % (rid, msg))
            w.set(rid, status="failed", error=msg)
            w.event("failed", region=rid, step="pack", error=msg)
            shutil.rmtree(w.p("tmp", rid), ignore_errors=True)
            return True
        rep = os.path.join(fdir, rid + ".pack.json")
        os.makedirs(w.p("reports"), exist_ok=True)
        if os.path.exists(rep):
            shutil.move(rep, w.p("reports", rid + ".pack.json"))
        size = os.path.getsize(pbf)
        self.pack_rate_bytes += size
        self.pack_rate_sec += sec
        w.set(rid, status="packed")
        w.event("packed", region=rid, bytes=size, seconds=round(sec, 2))
        os.remove(pbf)                       # данные теперь во фрагментах
        shutil.rmtree(w.p("tmp", rid), ignore_errors=True)
        return True

    def split(self, r):
        """Режет выгрузку родителя на части-прямоугольники одним проходом osmium extract; False — остановили."""
        w, rid = self.w, r["id"]
        pbf = w.p("dl", rid + ".osm.pbf")
        parts = [self.by_id[p] for p in r["parts"]]
        os.makedirs(w.p("tmp"), exist_ok=True)
        tmpn = {p["id"]: w.p("dl", p["id"] + ".tmp.osm.pbf") for p in parts}
        hdr = []                               # extract теряет osmosis_replication_timestamp: переносим вручную
        rc0, o0, _e0 = self.run_child([self.args.osmium, "fileinfo", "-g", "header.option.osmosis_replication_timestamp", pbf])
        if rc0 == 0 and o0.strip():
            hdr = ["--output-header", "osmosis_replication_timestamp=" + o0.strip()]
        batch = max(1, int(self.args.extract_batch))
        if os.path.getsize(pbf) > 2 * GB:       # замер: ~3,7 ГБ RSS на выход у KZ 0,22 ГБ; у больших родителей — по одному
            batch = 1
        w.event("split_start", region=rid, parts=len(parts), batch=batch)
        self.cur_region = rid
        t0 = time.time()
        rc, err = 0, ""
        for k in range(0, len(parts), batch):          # пачками: память smart-extract растёт с числом выходов за проход
            cfg = w.p("tmp", "%s.extract%d.json" % (rid, k // batch))
            json.dump({"directory": "/", "extracts": [{"output": tmpn[p["id"]], "bbox": p["bbox"]} for p in parts[k:k + batch]]}, open(cfg, "w"))
            rc, _o, err = self.run_child([self.args.osmium, "extract", "--strategy", "smart", "-c", cfg, "--overwrite"] + hdr + [pbf])
            if self.stop.is_set():
                return False
            if rc != 0:
                break
        self.cur_region = None
        if rc != 0 or not all(os.path.exists(f) for f in tmpn.values()):
            msg = "osmium extract: код %d: %s" % (rc, err.strip()[-300:])
            say("%s: ОШИБКА нарезки — %s" % (rid, msg))
            for f in tmpn.values():
                if os.path.exists(f):
                    os.remove(f)
            w.set(rid, status="failed", error=msg)
            for p in parts:
                w.set(p["id"], status="failed", error="нарезка родителя не удалась")
            w.event("failed", region=rid, step="split", error=msg)
            return True
        for p in parts:
            final = w.p("dl", p["id"] + ".osm.pbf")
            os.replace(tmpn[p["id"]], final)
            p["pbf_bytes"] = os.path.getsize(final)
            w.set(p["id"], status="downloaded", bytes_done=0, error="")
        os.remove(pbf)
        w.set(rid, status="split")
        w.event("split", region=rid, parts=len(parts), seconds=round(time.time() - t0, 2),
                part_bytes=[p["pbf_bytes"] for p in parts])
        return True

    def finalize_ready(self):
        """Склеивает всё, что готово; False — остановили."""
        for rid in self.ids:
            if self.w.reg(rid)["status"] != "packed":
                continue
            if not self.run_finalize(self.tiles_ready(rid)):
                return False
            self.maybe_done(rid)
        for r in self.regions:
            if r.get("parts") and self.w.reg(r["id"])["status"] == "split" and \
               all(self.w.reg(p)["status"] == "done" for p in r["parts"]):
                self.w.set(r["id"], status="done")
                self.w.event("done", region=r["id"])
        return True

    def run_finalize(self, ready):
        w = self.w
        for k in range(0, len(ready), FINALIZE_BATCH):
            batch = ready[k:k + FINALIZE_BATCH]
            os.makedirs(w.p("tmp"), exist_ok=True)
            lst, rep = w.p("tmp", "finalize.list"), w.p("tmp", "finalize.report.jsonl")
            with open(lst, "w") as f:
                for (j, i), sel in batch:
                    f.write("%d %d %s\n" % (j, i, " ".join(sel)))
            if os.path.exists(rep):
                os.remove(rep)
            cmd = [self.args.osmtiles, "finalize", "--frag-dir", w.p("frags"), "--out", self.args.out,
                   "--list", lst, "--report", rep]
            if self.args.threads:
                cmd += ["--threads", str(self.args.threads)]
            t0 = time.time()
            rc, _o, err = self.run_child(cmd)
            if self.stop.is_set():
                return False
            if rc != 0:
                raise RuntimeError("osmtiles finalize: код %d: %s" % (rc, err.strip()[-400:]))
            rows = read_jsonl(rep)
            if len(rows) != len(batch):
                raise RuntimeError("finalize вернул %d строк отчёта из %d тайлов" % (len(rows), len(batch)))
            with open(w.fin_path, "a") as f:
                for row in rows:
                    rec = {"j": row["j"], "i": row["i"], "bytes": row["bytes"], "sha256": row["sha256"]}
                    f.write(json.dumps(rec) + "\n")
                    self.finalized[(rec["j"], rec["i"])] = rec
                    self.tiles_bytes += rec["bytes"]
                f.flush()
                os.fsync(f.fileno())
            for (j, i), _sel in batch:              # фрагменты склеенных тайлов больше не нужны
                shutil.rmtree(os.path.join(w.p("frags"), str(j), str(i)), ignore_errors=True)
            partial = sorted({x for (t, _s) in batch for x in self.S[t] if x not in self.by_id})
            w.event("finalized", tiles=len(batch), seconds=round(time.time() - t0, 2),
                    **({"partial_outside": partial} if partial else {}))
        return True

    def maybe_done(self, rid):
        if all(t in self.finalized for t in self.cover.get(rid, [])):
            self.w.set(rid, status="done")
            self.w.event("done", region=rid)


def rates_from_log(w):
    """Скорости прошлых запусков (байт/с) скачивания и упаковки — для ETA сразу после старта и для status."""
    d_b = d_s = p_b = p_s = 0.0
    for e in read_jsonl(w.log_path):
        if e["event"] == "downloaded" and e.get("seconds"):
            d_b += e["bytes"]
            d_s += e["seconds"]
        elif e["event"] == "packed" and e.get("seconds"):
            p_b += e["bytes"]
            p_s += e["seconds"]
    return {"dl": d_b / d_s if d_s else None, "pack": p_b / p_s if p_s else None}


def take_lock(w):
    os.makedirs(w.dir, exist_ok=True)
    f = open(w.p("run.lock"), "w")
    if fcntl:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            sys.exit("в %s уже идёт другой run (run.lock занят)" % w.dir)
    return f


# ------------------------------------------------------------------ команды

def build_sources(w, regions):
    out = []
    for r in regions:
        if r.get("split_of"):
            continue
        rep = R.load_json(w.p("reports", (r["parts"][0] if r.get("parts") else r["id"]) + ".pack.json"), {})
        ts = rep.get("osm_timestamp", 0)
        if isinstance(ts, str):
            try:
                import calendar
                ts = calendar.timegm(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
            except ValueError:
                ts = 0
        out.append({"region": r["id"], "url": r["url"], "md5": w.reg(r["id"])["md5"], "osm_timestamp": ts,
                    "pbf_bytes": r["pbf_bytes"] if r.get("parts") else rep.get("input_bytes", r["pbf_bytes"])})
    return sorted(out, key=lambda s: s["region"])


def build_manifest(args, w, regions):
    src = w.p("sources.json")
    R.atomic_write(src, json.dumps(build_sources(w, regions), ensure_ascii=False, indent=1))
    out_pb = os.path.join(args.out, "v1", "manifest.pb")
    os.makedirs(os.path.dirname(out_pb), exist_ok=True)
    r = subprocess.run([args.osmtiles, "manifest", "--tiles", args.out, "--sources", src, "--out", out_pb],
                       capture_output=True, text=True)
    if r.returncode != 0:
        say("ОШИБКА манифеста: " + r.stderr.strip()[-400:])
        return 1
    w.event("manifest", path=out_pb, bytes=os.path.getsize(out_pb))
    say("готово: тайлы %s, манифест %s (%d байт)" % (args.out, out_pb, os.path.getsize(out_pb)))
    return 0


def cmd_run(args):
    w = Work(args.work)
    lockf = take_lock(w)     # noqa: F841  (держим до конца процесса)
    rj = ensure_plan(args, None if args.all else {x.strip() for x in (args.regions or "").split(",")})
    regions = select_regions(rj, args)
    state = w.load_state()
    state["out"] = os.path.abspath(args.out)
    os.makedirs(args.out, exist_ok=True)
    regions = expand_splits(args, w, state, regions)
    for r in regions:
        reg = state["regions"].setdefault(r["id"], {"status": "planned", "bytes_done": 0, "etag": "", "md5": "",
                                                    "attempts": 0, "error": ""})
        pbf = w.p("dl", r["id"] + ".osm.pbf")
        part = pbf + ".part"
        if reg["status"] == "failed":
            reg.update(status="planned", error="")
        if reg["status"] == "packing":
            reg["status"] = "downloaded"        # пакуется заново
        if reg["status"] == "downloaded" and not os.path.exists(pbf):
            reg.update(status="planned", bytes_done=0, etag="", md5="")
        if r.get("split_of") and reg["status"] == "planned" and state["regions"].get(r["split_of"], {}).get("status") in ("split", "done"):
            # родитель уже разрезан, а выгрузки части нет — качать и резать родителя заново
            state["regions"][r["split_of"]].update(status="planned", bytes_done=0, etag="", md5="")
        if reg["status"] in ("planned", "downloading"):
            reg["bytes_done"] = os.path.getsize(part) if os.path.exists(part) else 0
    ctx = Ctx(args, w, rj, regions)
    for r in regions:       # done без полного набора склеенных тайлов (удалён finalized.jsonl и т. п.) — не доверяем
        reg = w.reg(r["id"])
        if reg["status"] == "done" and not all(t in ctx.finalized for t in ctx.cover.get(r["id"], [])):
            say("%s: помечен done, но тайлы не все склеены — делаю заново" % r["id"])
            reg.update(status="planned", bytes_done=0, etag="", md5="")
    w.save()
    todo = [r for r in regions if w.reg(r["id"])["status"] != "done"]
    say("work %s · регионов %d (готово %d) · скачать %s ГБ · свободно на диске %s ГБ · запас %s ГБ" % (
        w.dir, len(regions), len(regions) - len(todo), fmt_gb(sum(r["pbf_bytes"] for r in todo)),
        fmt_gb(free_bytes(w.dir)), fmt_gb(ctx.keep_free)))
    w.event("run_start", regions=len(regions), todo=len(todo), out=state["out"])

    def on_sig(_s, _f):
        if ctx.user_stop:
            raise KeyboardInterrupt
        ctx.user_stop = True
        ctx.stop.set()
        say("\nостанавливаюсь (Ctrl-C ещё раз — немедленно); состояние сохранено, повторный run продолжит…")
    signal.signal(signal.SIGINT, on_sig)
    signal.signal(signal.SIGTERM, on_sig)

    dl = Downloader(ctx, regions)
    ctx.dl = dl
    dl.start()
    fatal = None
    try:
        ctx.finalize_ready()
        while not ctx.stop.is_set():
            fin = dl.finished
            nxt = next((r for r in regions if w.reg(r["id"])["status"] == "downloaded"), None)
            if nxt:
                ok = ctx.split(nxt) if nxt.get("parts") else ctx.pack(nxt)
                if not ok or not ctx.finalize_ready():
                    break
                continue
            if fin:
                break
            ctx.tick()
            time.sleep(0.3)
    except RuntimeError as e:
        fatal = str(e)
        ctx.stop.set()
    except KeyboardInterrupt:
        ctx.user_stop = True
        ctx.stop.set()
    finally:
        dl.join(15)
        w.save()
        ctx.newline()
    fatal = fatal or dl.fatal
    if fatal:
        say("ОСТАНОВЛЕНО: " + fatal)
        w.event("fatal", error=fatal)
        return 1
    if ctx.user_stop:
        say("остановлено; повторите ту же команду run — продолжит с места остановки")
        w.event("interrupted")
        return 130
    st = {s: sum(1 for r in regions if w.reg(r["id"])["status"] == s) for s in STATUSES}
    failed = [r["id"] for r in regions if w.reg(r["id"])["status"] == "failed"]
    unfinished = [r["id"] for r in regions if w.reg(r["id"])["status"] not in ("done", "failed", "split")]
    import resource
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024.0
    w.event("run_end", statuses=st, seconds=round(time.time() - ctx.t_start, 1),
            peak_disk_gb=round(ctx.peak_disk / GB, 3), child_rss_mb=round(rss, 1))
    if failed:
        say("не удались регионы: %s — повторный run попробует снова (причины: world.py status)" % ", ".join(failed))
        return 1
    if unfinished:
        say("не завершены (ждут соседей вне списка или упаковки): %s" % ", ".join(unfinished))
        return 1
    return build_manifest(args, w, regions)


def cmd_status(args):
    w = Work(args.work)
    st = w.load_state()
    regs = st["regions"]
    if not regs:
        print("regions done 0/0 (запусков ещё не было)")
        return 0
    cnt = {s: sum(1 for r in regs.values() if r["status"] == s) for s in STATUSES}
    print("regions done %d/%d" % (cnt["done"], len(regs)))
    print("по статусам: " + ", ".join("%s %d" % (s, cnt[s]) for s in STATUSES if cnt[s]))
    uniq = {(r["j"], r["i"]): r for r in read_jsonl(w.fin_path)}
    print("тайлов %s (%s ГБ)" % (fmt_n(len(uniq)), fmt_gb(sum(r["bytes"] for r in uniq.values()))))
    rj = R.load_json(w.p("regions.json"), {"regions": []})
    size = {r["id"]: r["pbf_bytes"] for r in rj["regions"]}
    tot = sum(size.get(i, 0) for i in regs)
    done = sum(size.get(i, 0) if r["status"] in ("downloaded", "packing", "packed", "done") else r["bytes_done"]
               for i, r in regs.items())
    print("скачано %s из %s ГБ" % (fmt_gb(done), fmt_gb(tot)))
    left = [i for i, r in regs.items() if r["status"] != "done"]
    if left:
        rt = rates_from_log(w)
        t = []
        if rt["dl"]:
            t.append((tot - done) / rt["dl"])
        if rt["pack"]:
            t.append(sum(size.get(i, 0) for i in left) / rt["pack"])
        print("осталось регионов %d · ETA %s" % (len(left), fmt_eta(max(t)) if t else "? (нет замеров)"))
    for i, r in regs.items():
        if r["status"] == "failed":
            print("  ОШИБКА %s: %s" % (i, r["error"]))
    ev = read_jsonl(w.log_path)
    if ev:
        last = ev[-1]
        print("последнее событие: %s %s (%s)" % (last["event"], last.get("region", ""),
                                                time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(last["t"]))))
    return 0


def cmd_plan(args):
    w = Work(args.work)
    rj = ensure_plan(args, None)
    regions = select_regions(rj, args) if (args.regions or args.all) else rj["regions"]
    cover, _s = load_covers(w, rj)
    tiles = set()
    for r in regions:
        tiles.update(cover.get(r["id"], []))
    print("регионов %d · скачать %s ГБ · тайлов (cover) %s" % (len(regions), fmt_gb(sum(r["pbf_bytes"] for r in regions)),
                                                              fmt_n(len(tiles))))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--work", required=True)
        p.add_argument("--regions", help="id через запятую (из regions.json)")
        p.add_argument("--all", action="store_true", help="весь набор регионов")
        p.add_argument("--max-region-gb", type=float, default=2.0)
        p.add_argument("--osmtiles", default=DEFAULT_BIN)
        p.add_argument("--osmium", default="osmium", help="osmium для нарезки больших регионов (O8 v2)")
        p.add_argument("--extract-batch", type=int, default=2, help="частей за один проход osmium extract (память!)")
        p.add_argument("--seed-from", help="готовый каталог плана OT-5 (index, heads, regions.json, poly, cover) — только чтение")
    r = sub.add_parser("run")
    common(r)
    r.add_argument("--out", required=True)
    r.add_argument("--keep-free-gb", type=float, default=20.0)
    r.add_argument("--threads", type=int, default=0)
    r.add_argument("--log", help="писать строки прогресса (без перерисовок) в файл вместо stdout")
    r.set_defaults(fn=cmd_run)
    s = sub.add_parser("status")
    s.add_argument("--work", required=True)
    s.set_defaults(fn=cmd_status)
    p = sub.add_parser("plan")
    common(p)
    p.set_defaults(fn=cmd_plan)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
