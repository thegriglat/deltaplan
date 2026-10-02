#!/usr/bin/env python3
"""Набор пилота air-nn (NN-P1): план, счёт с продолжения, сводка. Контракт — docs/air_nn_contracts.md, П1 v1.

  PY=.venv/bin/python
  $PY dataset.py plan   [--dataset main]                 # план (идемпотентно): plan.json, state.sqlite, manifest.json
  $PY dataset.py run    [--dataset main] [--ids a,b] [--limit N] [--finish-on-signal]
  $PY dataset.py status [--dataset main] [--check]
  $PY dataset.py export [--dataset main] [--out cases.jsonl]  # метаданные случаев (как runs.jsonl air-lite)
  $PY dataset.py path   [--dataset main]                 # каталог набора (для скриптов)
Общие: --config configs/dataset.yaml, --data-root (иначе $AIR_NN_DATA, иначе data_root конфига).

Каталог набора: $AIR_NN_DATA/pilot/datasets/s0-<хеш air3d/*.py>/<набор>/{manifest.json, plan.json, state.sqlite,
cases/<id>.npz}; временное — $AIR_NN_DATA/pilot/tmp/<версия>_<набор>/.

Коды выхода run: 0 — выбранное посчитано (для всего набора — набор готов); 2 — остановлен сигналом;
3 — мало места на диске; 4 — есть упавшие случаи (ошибок ≥ max_failures); 5 — уже идёт другой run этого набора;
1 — прочие ошибки.
"""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import traceback
import zipfile
from pathlib import Path

import numpy as np
import yaml

HERE = Path(__file__).resolve().parent
AIR3D = HERE.parent / "air3d"
SCHEMA_VERSION = 1
CONTRACT = "П1 v1"
GPU_LOCK = "/tmp/heat_ca_gpu.lock"
EXIT_OK, EXIT_ERR, EXIT_SIGNAL, EXIT_DISK, EXIT_FAILED, EXIT_BUSY = 0, 1, 2, 3, 4, 5
ZIP_DATE = (1980, 1, 1, 0, 0, 0)


_LOG = None   # --log ФАЙЛ: подробный журнал в файл (дописывается), иначе — stdout


def log(msg):
    line = f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} {msg}"
    if _LOG is not None:
        _LOG.write(line + "\n")
        _LOG.flush()
    else:
        print(line, flush=True)


# ------------------------------------------------------------------------------------------- версии, пути
def solver_version():
    """s0-<7 знаков sha1> от кода эталона tools/research/air3d/*.py (имя + содержимое, по имени)."""
    h = hashlib.sha1()
    for p in sorted(AIR3D.glob("*.py")):
        h.update(p.name.encode() + b"\0" + p.read_bytes() + b"\0")
    return "s0-" + h.hexdigest()[:7]


def git_commit():
    try:
        c = subprocess.run(["git", "-C", str(HERE), "rev-parse", "--short=10", "HEAD"], capture_output=True, text=True,
                           timeout=10).stdout.strip()
        dirty = subprocess.run(["git", "-C", str(HERE), "status", "--porcelain", "--", "."], capture_output=True, text=True,
                               timeout=10).stdout.strip()
        return c + ("+dirty" if dirty else "")
    except Exception:  # noqa: BLE001
        return "unknown"


def kind_of(loc):
    return "proc" if loc.startswith("p_") else ("synth" if loc.startswith("s_") else "real")


class Layout:
    def __init__(self, cfg, data_root, name):
        self.root = Path(data_root) / "pilot"
        self.name = name
        self.version = solver_version()
        self.dir = self.root / "datasets" / self.version / name
        self.cases = self.dir / "cases"
        self.db = self.dir / "state.sqlite"
        self.plan = self.dir / "plan.json"
        self.manifest = self.dir / "manifest.json"
        self.tmp = self.root / "tmp" / f"{self.version}_{name}"

    def case_file(self, cid):
        return self.cases / f"{cid}.npz"


def load_cfg(path):
    return yaml.safe_load(Path(path).read_text())


def data_root(a, cfg):
    return a.data_root or os.environ.get("AIR_NN_DATA") or cfg["data_root"]


# ------------------------------------------------------------------------------------------- запись атомарно
def fsync_dir(d):
    fd = os.open(d, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write_bytes(path, data, tmpdir):
    tmpdir.mkdir(parents=True, exist_ok=True)
    t = tmpdir / f"{path.name}.{os.getpid()}.part"
    with open(t, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(t, path)
    fsync_dir(path.parent)


def write_npz(f, arrays):
    """npz как np.savez_compressed, но побитно повторяемый: фиксированная дата записей zip, порядок ключей — как дан."""
    with zipfile.ZipFile(f, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for k, v in arrays.items():
            zi = zipfile.ZipInfo(k + ".npy", date_time=ZIP_DATE)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            with zf.open(zi, "w", force_zip64=True) as fh:
                np.lib.format.write_array(fh, np.asanyarray(v), allow_pickle=False)


def test_pause(where, cid):
    """Только для теста прерывания: AIRNN_P1_TEST_PAUSE=<с> — пауза в узких местах записи (метка в лог)."""
    p = float(os.environ.get("AIRNN_P1_TEST_PAUSE", "0") or 0)
    if p > 0:
        log(f"[test] pause {where} {cid}")
        time.sleep(p)


# ------------------------------------------------------------------------------------------- план
def build_plan(cfg, name):
    """План набора: air-lite (те же id и условия, что out/plan.json ветки research/air-lite) + процедурные; подмножество
    для наборов кроме main. Возвращает dict для plan.json."""
    import airlite_gen as G
    import places as P
    import procedural as PR
    pc = cfg["plan"]
    PR.configure(pc["proc_seed"])
    base_locs = list(P.REAL + P.SYNTH)
    rows = G.plan_rows(base_locs, lambda l: pc["n_real"] if l in P.REAL else pc["n_synth"], seed=pc["airlite_seed"])
    proc_locs = [f"p_{k:03d}" for k in range(pc["n_proc"])]
    rows += G.plan_rows(proc_locs, lambda l: pc["n_proc_cond"], seed=pc["proc_cond_seed"])
    spec = cfg["datasets"][name]
    if spec.get("places"):
        keep = set(spec["places"])
        nc = spec.get("n_cond", 10 ** 9)
        rows = [r for r in rows if r["loc"] in keep and int(r["id"].rsplit("_", 1)[1]) < nc]
    locs = list(dict.fromkeys(r["loc"] for r in rows))
    centers = G.plan_centers(locs)
    # чередовать места: любой префикс прогона покрывает все места (как air-lite)
    order = sorted(rows, key=lambda c: (int(c["id"].rsplit("_", 1)[1]), c["loc"]))
    procs = {loc: PR.params(int(loc[2:])) for loc in locs if loc.startswith("p_")}
    return dict(agl=list(G.AGL), centers=centers, cases=rows, seed=pc["airlite_seed"],
                proc=dict(seed=pc["proc_seed"], cond_seed=pc["proc_cond_seed"], n_cond=pc["n_proc_cond"], params=procs),
                places=locs, order=[r["id"] for r in order], dataset=name)


def plan_hash(plan):
    return hashlib.sha256(json.dumps(plan, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS cases (
  id TEXT PRIMARY KEY, loc TEXT NOT NULL, kind TEXT NOT NULL, ord INTEGER NOT NULL, cond TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'planned' CHECK (status IN ('planned','running','done','failed')),
  attempts INTEGER NOT NULL DEFAULT 0, failures INTEGER NOT NULL DEFAULT 0,
  pid INTEGER, host TEXT, started REAL, finished REAL, t_wall REAL, iters INTEGER, solve_status TEXT,
  runs TEXT, meta TEXT, file TEXT, bytes INTEGER, sha256 TEXT, error TEXT);
CREATE INDEX IF NOT EXISTS cases_q ON cases (status, ord);
CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, t REAL NOT NULL, pid INTEGER, case_id TEXT,
  kind TEXT NOT NULL, msg TEXT);
CREATE TABLE IF NOT EXISTS batches (id INTEGER PRIMARY KEY AUTOINCREMENT, pid INTEGER, t_start REAL, t_end REAL,
  lock_wait REAL, n_cases INTEGER, code TEXT);
"""


def connect(path):
    con = sqlite3.connect(str(path), timeout=60.0, isolation_level=None)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=FULL")
    con.execute("PRAGMA busy_timeout=60000")
    con.row_factory = sqlite3.Row
    return con


def event(con, kind, msg="", case_id=None):
    con.execute("INSERT INTO events (t, pid, case_id, kind, msg) VALUES (?,?,?,?,?)",
                (time.time(), os.getpid(), case_id, kind, msg))


def write_root_readme(L):
    L.root.mkdir(parents=True, exist_ok=True)
    txt = (HERE / "data_readme.md").read_text()
    p = L.root / "README.md"
    if not p.exists() or p.read_text() != txt:
        atomic_write_bytes(p, txt.encode(), L.root / "tmp")


def write_manifest(L, con, extra=None):
    m = json.loads(L.manifest.read_text()) if L.manifest.exists() else {}
    n = dict(con.execute("SELECT status, COUNT(*) FROM cases GROUP BY status").fetchall())
    size = sum(f.stat().st_size for f in L.cases.glob("*.npz")) if L.cases.exists() else 0
    m.update(dict(
        what=f"набор пилота air-nn «{L.name}»: решения эталона AM-01 (air3d, «как игра») — область 400 м 96² и окна "
             "100 м 64² на 13 высотах AGL, с нагревом и без; места × условия по plan.json",
        contract=CONTRACT, solver_version=L.version, schema_version=SCHEMA_VERSION,
        code="tools/research/air_nn_pilot (dataset.py, airlite_gen.py, places.py, procedural.py)",
        commands=[f"cd tools/research/air_nn_pilot && .venv/bin/python dataset.py plan --dataset {L.name}",
                  f"cd tools/research/air_nn_pilot && .venv/bin/python dataset.py run --dataset {L.name}"],
        inputs=dict(solver="tools/research/air3d/*.py (не правится)", places="data/terrain/<место>, configs/locations",
                    airlite="research/air-lite 7cc7e33 tools/research/air_lite/{gen.py, places.py}"),
        counts=dict(total=sum(n.values()), **n), size_bytes=size,
        complete=sum(n.values()) > 0 and n.get("done", 0) == sum(n.values()),
        updated=dt.datetime.now().isoformat(timespec="seconds")))
    if extra:
        m.update(extra)
    atomic_write_bytes(L.manifest, (json.dumps(m, ensure_ascii=False, indent=1) + "\n").encode(), L.tmp)


def cmd_plan(cfg, L, quiet=False):
    plan = build_plan(cfg, L.name)
    ph = plan_hash(plan)
    write_root_readme(L)
    L.cases.mkdir(parents=True, exist_ok=True)
    L.tmp.mkdir(parents=True, exist_ok=True)
    if L.plan.exists():
        old = json.loads(L.plan.read_text())
        if plan_hash(old) != ph:
            log(f"ОШИБКА: план набора {L.dir} отличается от конфига — набор с другим планом заведите под новым именем")
            return EXIT_ERR
    else:
        atomic_write_bytes(L.plan, (json.dumps(plan, ensure_ascii=False, indent=1) + "\n").encode(), L.tmp)
    con = connect(L.db)
    con.executescript(SCHEMA)
    con.execute("BEGIN IMMEDIATE")
    meta = dict(schema_version=str(SCHEMA_VERSION), solver_version=L.version, contract=CONTRACT, plan_sha256=ph,
                dataset=L.name)
    for k, v in meta.items():
        old = con.execute("SELECT value FROM meta WHERE key=?", (k,)).fetchone()
        if old is not None and old[0] != v:
            con.execute("ROLLBACK")
            log(f"ОШИБКА: meta.{k} базы = {old[0]}, ожидалось {v}")
            return EXIT_ERR
        con.execute("INSERT OR IGNORE INTO meta (key, value) VALUES (?,?)", (k, v))
    con.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('created', ?)", (dt.datetime.now().isoformat(timespec="seconds"),))
    con.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('code_at_plan', ?)", (git_commit(),))
    ordmap = {cid: i for i, cid in enumerate(plan["order"])}
    n_new = 0
    for c in plan["cases"]:
        cur = con.execute("INSERT OR IGNORE INTO cases (id, loc, kind, ord, cond) VALUES (?,?,?,?,?)",
                          (c["id"], c["loc"], kind_of(c["loc"]), ordmap[c["id"]], json.dumps(c, ensure_ascii=False)))
        n_new += cur.rowcount
    if n_new:
        event(con, "plan", f"{n_new} случаев добавлено")
    con.execute("COMMIT")
    write_manifest(L, con, dict(created=con.execute("SELECT value FROM meta WHERE key='created'").fetchone()[0],
                                plan=dict(sha256=ph, n_cases=len(plan["cases"]), places=plan["places"], seeds=cfg["plan"])))
    con.close()
    if not quiet:
        by = {}
        for c in plan["cases"]:
            by[kind_of(c["loc"])] = by.get(kind_of(c["loc"]), 0) + 1
        log(f"план {L.name}: {len(plan['cases'])} случаев {by}, мест {len(plan['places'])}, новых в базе {n_new}; {L.dir}")
    return EXIT_OK


# ------------------------------------------------------------------------------------------- счёт
LOCK_YIELD_S = 2.0


class Abandon(BaseException):
    pass


class Stopper:
    def __init__(self, finish):
        self.requested = 0
        self.in_solve = False
        self.in_lock = False
        self.finish = finish

    def __call__(self, sig, frame):
        self.requested += 1
        if self.requested > 1:
            os.write(2, f"второй сигнал {sig} — немедленный выход\n".encode())
            os._exit(128 + sig)
        log(f"сигнал {sig}: мягкая остановка ({'дописать' if self.finish else 'бросить'} текущий случай)")
        if self.in_lock or (self.in_solve and not self.finish):
            raise Abandon()


class GpuLock:
    """flock на /tmp/heat_ca_gpu.lock: блокирующее ожидание; сигнал прерывает его (Abandon через stop.in_lock)."""

    def __init__(self, stop):
        self.stop = stop

    def __enter__(self):
        self.f = open(GPU_LOCK, "a")
        t0 = time.perf_counter()
        try:
            self.stop.in_lock = True
            if self.stop.requested:
                raise Abandon()
            fcntl.flock(self.f, fcntl.LOCK_EX)
            self.stop.in_lock = False
        except BaseException:
            self.stop.in_lock = False
            self.f.close()  # закрытие снимает замок, если он успел взяться
            raise
        self.wait = time.perf_counter() - t0
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def recover(con, L):
    """Вызывается под замком запускающего: все `running` — от умерших процессов (другого run нет)."""
    con.execute("BEGIN IMMEDIATE")
    rows = con.execute("SELECT id, pid FROM cases WHERE status='running'").fetchall()
    for r in rows:
        event(con, "recovered", f"running (pid {r['pid']}) → planned", r["id"])
    con.execute("UPDATE cases SET status='planned', pid=NULL, host=NULL WHERE status='running'")
    con.execute("COMMIT")
    n_tmp = 0
    for p in L.tmp.glob("*.part"):
        p.unlink()
        n_tmp += 1
    if rows or n_tmp:
        log(f"продолжение: возвращено в очередь {len(rows)} ({', '.join(r['id'] for r in rows)}), удалено недописанных {n_tmp}")


def claim(con, ids, max_failures):
    q = ("UPDATE cases SET status='running', pid=?, host=?, started=?, attempts=attempts+1, error=NULL "
         "WHERE id = (SELECT id FROM cases WHERE (status='planned' OR (status='failed' AND failures < ?)) {} "
         "ORDER BY ord LIMIT 1) RETURNING id, cond")
    extra, args = "", []
    if ids:
        extra = f"AND id IN ({','.join('?' * len(ids))})"
        args = list(ids)
    con.execute("BEGIN IMMEDIATE")
    r = con.execute(q.format(extra), [os.getpid(), socket.gethostname(), time.time(), max_failures, *args]).fetchone()
    con.execute("COMMIT")
    return r


def remaining(con, ids, max_failures):
    q = "SELECT COUNT(*) FROM cases WHERE (status IN ('planned','running') OR (status='failed' AND failures < ?))"
    args = [max_failures]
    if ids:
        q += f" AND id IN ({','.join('?' * len(ids))})"
        args += list(ids)
    return con.execute(q, args).fetchone()[0]


def show_progress(con, cfg, L, end=""):
    """Одна обновляемая строка на stdout (\r): «сделано/всего (%), осталось ~ETA» по всему набору."""
    sys.stdout.write("\r\033[K" + progress_line(summary(con, cfg, L)) + end)
    sys.stdout.flush()


def free_gpu():
    try:
        import cupy as cp
        cp.get_default_memory_pool().free_all_blocks()
    except Exception:  # noqa: BLE001
        pass


def cmd_run(cfg, L, a):
    if not (L.plan.exists() and L.db.exists()):   # план есть — берём plan.json (проверка против конфига — команда plan)
        rc = cmd_plan(cfg, L, quiet=True)
        if rc:
            return rc
    rcfg = cfg["run"]
    batch_s = a.batch_s or rcfg["batch_s"]
    max_fail = rcfg["max_failures"]
    min_free = rcfg["min_free_gb"] * 1e9
    runner = open(L.tmp / "runner.lock", "a")
    try:
        fcntl.flock(runner, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log(f"ОШИБКА: run набора {L.name} уже идёт (замок {L.tmp / 'runner.lock'})")
        return EXIT_BUSY
    stop = Stopper(a.finish_on_signal)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    plan = json.loads(L.plan.read_text())
    import procedural as PR
    PR.configure(plan["proc"]["seed"])
    import airlite_gen as G
    con = connect(L.db)
    recover(con, L)
    ids = [s for s in a.ids.split(",") if s] if a.ids else None
    code = git_commit()
    total = con.execute("SELECT COUNT(*) FROM cases").fetchone()[0]
    left0 = remaining(con, ids, max_fail)
    todo = min(left0, a.limit) if a.limit else left0
    log(f"run {L.name} ({L.version}, код {code}): к счёту {todo} из {left0} оставшихся, всего в наборе {total}; {L.dir}")
    t_start = time.time()
    n_run, t_cases, rc = 0, 0.0, EXIT_OK
    if a.progress:
        show_progress(con, cfg, L)
    while not stop.requested and (not a.limit or n_run < a.limit):
        if remaining(con, ids, max_fail) == 0:
            break
        free_b = shutil.disk_usage(L.dir).free
        if free_b < min_free:
            log(f"СТОП: на диске данных свободно {free_b / 1e9:.1f} ГБ < {min_free / 1e9:.0f} ГБ — освободите место и запустите run снова")
            rc = EXIT_DISK
            break
        try:
            lk = GpuLock(stop).__enter__()
        except Abandon:
            break
        t_b, n_b = time.time(), 0
        log(f"  пачка: замок GPU получен (ждал {lk.wait:.0f} с)")
        try:
            while not stop.requested and (not a.limit or n_run < a.limit) and time.time() - t_b < batch_s:
                r = claim(con, ids, max_fail)
                if r is None:
                    break
                cid, c = r["id"], json.loads(r["cond"])
                t0 = time.perf_counter()
                try:
                    stop.in_solve = True
                    res, arrays = G.solve_case(c, plan["centers"][c["loc"]])
                    stop.in_solve = False
                except Abandon:
                    stop.in_solve = False
                    free_gpu()
                    con.execute("BEGIN IMMEDIATE")
                    con.execute("UPDATE cases SET status='planned', pid=NULL WHERE id=?", (cid,))
                    event(con, "abandoned", "сигнал: случай брошен, возвращён в очередь", cid)
                    con.execute("COMMIT")
                    log(f"  {cid}: брошен, возвращён в очередь")
                    break
                except Exception as e:  # noqa: BLE001
                    stop.in_solve = False
                    free_gpu()
                    err = f"{type(e).__name__}: {e}"
                    con.execute("BEGIN IMMEDIATE")
                    con.execute("UPDATE cases SET status='failed', failures=failures+1, pid=NULL, error=?, finished=? WHERE id=?",
                                (err + "\n" + traceback.format_exc()[-2000:], time.time(), cid))
                    event(con, "failed", err, cid)
                    con.execute("COMMIT")
                    log(f"  {cid}: ОШИБКА {err}")
                    n_run += 1
                    continue
                st = [v["status"] for v in res["runs"].values()]
                sst = "ok" if all(s == "ok" for s in st) else ("diverged" if "diverged" in st else "max")
                its = int(sum(v["iters"] for v in res["runs"].values()))
                # данные → временный файл → fsync → переименование → только затем done
                path = L.case_file(cid)
                L.tmp.mkdir(parents=True, exist_ok=True)
                tpart = L.tmp / f"{cid}.{os.getpid()}.part"
                with open(tpart, "wb") as f:
                    write_npz(f, arrays)
                    f.flush()
                    os.fsync(f.fileno())
                test_pause("before-rename", cid)
                existed = path.exists()
                os.replace(tpart, path)
                fsync_dir(L.cases)
                test_pause("before-done", cid)
                nbytes = path.stat().st_size
                sha = hashlib.sha256(path.read_bytes()).hexdigest()
                t_wall = round(time.perf_counter() - t0, 2)
                row = dict(c)
                row.update(res)
                row.update(status=sst, t_wall=t_wall)
                con.execute("BEGIN IMMEDIATE")
                con.execute("UPDATE cases SET status='done', pid=NULL, finished=?, t_wall=?, iters=?, solve_status=?, runs=?, "
                            "meta=?, file=?, bytes=?, sha256=?, error=NULL WHERE id=?",
                            (time.time(), t_wall, its, sst, json.dumps(res["runs"], default=float),
                             json.dumps(row, default=float, ensure_ascii=False), f"cases/{cid}.npz", nbytes, sha, cid))
                if existed:
                    event(con, "overwrite", "файл был (обрыв между данными и статусом) — перезаписан", cid)
                con.execute("COMMIT")
                n_run += 1
                n_b += 1
                t_cases += t_wall
                left = remaining(con, ids, max_fail)
                eta = t_cases / n_run * (min(left, a.limit - n_run) if a.limit else left) / 3600
                log(f"[{(time.time() - t_start) / 60:6.1f} мин] {n_run}/{todo} {cid}: {sst}, {its} ит., {t_wall:.1f} с, "
                    f"{nbytes / 1e6:.2f} МБ | осталось {left}, ETA {eta:.2f} ч")
                if a.progress:
                    show_progress(con, cfg, L)
        finally:
            lk.__exit__()
            con.execute("INSERT INTO batches (pid, t_start, t_end, lock_wait, n_cases, code) VALUES (?,?,?,?,?,?)",
                        (os.getpid(), t_b, time.time(), lk.wait, n_b, code))
        log(f"  пачка: {n_b} случаев, замок GPU отпущен")
        if not stop.requested:
            time.sleep(LOCK_YIELD_S)  # уступить ждущим на замке
    if stop.requested:
        rc = EXIT_SIGNAL
    elif rc == EXIT_OK:
        nf = con.execute("SELECT COUNT(*) FROM cases WHERE status='failed' AND failures >= ?" +
                         (f" AND id IN ({','.join('?' * len(ids))})" if ids else ""), [max_fail, *(ids or [])]).fetchone()[0]
        if nf:
            rc = EXIT_FAILED
    write_manifest(L, con)
    if a.progress:
        show_progress(con, cfg, L, end="\n")
    con.close()
    log(f"run {L.name}: посчитано {n_run} за {(time.time() - t_start) / 3600:.2f} ч, код выхода {rc}")
    return rc


# ------------------------------------------------------------------------------------------- сводка
def summary(con, cfg, L):
    """Сводка набора (для status, status --json и строки прогресса run): счётчики — по всей базе, с учётом посчитанного
    до любых обрывов."""
    max_fail = cfg["run"]["max_failures"]
    n = dict(con.execute("SELECT status, COUNT(*) FROM cases GROUP BY status").fetchall())
    ss = dict(con.execute("SELECT solve_status, COUNT(*) FROM cases WHERE status='done' GROUP BY solve_status").fetchall())
    tot = sum(n.values())
    out = dict(dataset=L.name, solver_version=L.version, dir=str(L.dir), total=tot, done=n.get("done", 0),
               planned=n.get("planned", 0), running=n.get("running", 0), failed=n.get("failed", 0),
               failed_final=con.execute("SELECT COUNT(*) FROM cases WHERE status='failed' AND failures >= ?",
                                        (max_fail,)).fetchone()[0],
               ok=ss.get("ok", 0), max=ss.get("max", 0), diverged=ss.get("diverged", 0), kinds={})
    all_t = [r[0] for r in con.execute("SELECT t_wall FROM cases WHERE status='done'")]
    eta_s = 0.0
    for kind in ("real", "synth", "proc"):
        k_tot = con.execute("SELECT COUNT(*) FROM cases WHERE kind=?", (kind,)).fetchone()[0]
        if not k_tot:
            continue
        rows = con.execute("SELECT t_wall, solve_status, bytes FROM cases WHERE kind=? AND status='done'", (kind,)).fetchall()
        ts = [r[0] for r in rows]
        k = dict(total=k_tot, done=len(rows))
        if ts:
            k.update(mean_s=round(float(np.mean(ts)), 2), median_s=round(float(np.median(ts)), 2),
                     max_frac=round(sum(r[1] == "max" for r in rows) / len(rows), 3),
                     mean_mb=round(float(np.mean([r[2] for r in rows])) / 1e6, 3))
        mean = float(np.mean(ts)) if ts else (float(np.mean(all_t)) if all_t else None)
        if mean is None:
            eta_s = None
        elif eta_s is not None:
            eta_s += (k_tot - len(rows)) * mean
        out["kinds"][kind] = k
    out["eta_h"] = None if eta_s is None else round(eta_s / 3600, 3)
    b = con.execute("SELECT SUM(n_cases), SUM(t_end - t_start), SUM(lock_wait) FROM batches").fetchone()
    out["rate_per_h"] = round(b[0] / (b[1] / 3600), 1) if b[0] and b[1] else None
    out["batches_h"] = round((b[1] or 0) / 3600, 3)
    out["gpu_wait_min"] = round((b[2] or 0) / 60, 2)
    files = list(L.cases.glob("*.npz"))
    out["cases_gb"] = round(sum(f.stat().st_size for f in files) / 1e9, 4)
    out["n_files"] = len(files)
    out["db_mb"] = round(sum(p.stat().st_size for p in L.dir.glob("state.sqlite*")) / 1e6, 2)
    out["events"] = dict(con.execute("SELECT kind, COUNT(*) FROM events GROUP BY kind").fetchall())
    out["complete"] = tot > 0 and out["done"] == tot
    return out


def progress_line(S):
    pct = 100.0 * S["done"] / max(S["total"], 1)
    eta = "?" if S["eta_h"] is None else (f"{S['eta_h']:.1f} ч" if S["eta_h"] >= 1 else f"{S['eta_h'] * 60:.0f} мин")
    extra = f", ошибок {S['failed']}" if S["failed"] else ""
    return f"{S['done']}/{S['total']} ({pct:.1f}%), осталось ~{eta}{extra}"


def cmd_status(cfg, L, a):
    if not L.db.exists():
        if a.json:
            print(json.dumps(dict(dataset=L.name, dir=str(L.dir), total=0, done=0, complete=False, eta_h=None)))
        else:
            log(f"набор {L.name}: нет базы ({L.db}) — сначала plan/run")
        return EXIT_ERR if a.check else EXIT_OK
    con = connect(L.db)
    S = summary(con, cfg, L)
    con.close()
    if a.json:
        print(json.dumps(S, ensure_ascii=False))
    else:
        print(f"набор {L.name} ({L.version}) — {L.dir}")
        print(f"  всего {S['total']}: done {S['done']} (ok {S['ok']}, max {S['max']}, diverged {S['diverged']}), "
              f"planned {S['planned']}, running {S['running']}, failed {S['failed']} (из них окончательно {S['failed_final']})")
        print("  по видам: done/всего, среднее и медиана времени случая, доля max, средний размер файла:")
        for kind, k in S["kinds"].items():
            if k["done"]:
                print(f"    {kind:5s} {k['done']}/{k['total']}: {k['mean_s']:.1f} с, {k['median_s']:.1f} с, {k['max_frac']:.0%}, "
                      f"{k['mean_mb']:.2f} МБ")
            else:
                print(f"    {kind:5s} 0/{k['total']}")
        if S["rate_per_h"]:
            print(f"  скорость: {S['rate_per_h']:.0f} случаев/ч в пачках (пачки {S['batches_h']:.2f} ч, ожидание GPU "
                  f"{S['gpu_wait_min']:.1f} мин)")
        print(f"  ETA (оставшиеся × среднее время своего вида): " + ("нет замеров" if S["eta_h"] is None else f"{S['eta_h']:.2f} ч"))
        print(f"  на диске: случаи {S['cases_gb']:.3f} ГБ ({S['n_files']} файлов), база {S['db_mb']:.1f} МБ")
        ev = S["events"]
        print(f"  события: возвращено в очередь {ev.get('recovered', 0)}, брошено по сигналу {ev.get('abandoned', 0)}, "
              f"перезаписано {ev.get('overwrite', 0)}, ошибок {ev.get('failed', 0)}")
        print(f"  прогресс: {progress_line(S)}")
    if a.check:
        return EXIT_OK if S["complete"] else EXIT_ERR
    return EXIT_OK


def cmd_export(cfg, L, a):
    con = connect(L.db)
    out = Path(a.out) if a.out else None
    lines = []
    for r in con.execute("SELECT meta FROM cases WHERE status='done' ORDER BY ord"):
        lines.append(r[0])
    txt = "\n".join(lines) + ("\n" if lines else "")
    if out:
        out.write_text(txt)
        log(f"{len(lines)} строк → {out}")
    else:
        sys.stdout.write(txt)
    return EXIT_OK


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=("plan", "run", "status", "export", "path"))
    ap.add_argument("--config", default=str(HERE / "configs/dataset.yaml"))
    ap.add_argument("--data-root", default=None)
    ap.add_argument("--dataset", default="main")
    ap.add_argument("--ids", default="")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--batch-s", type=float, default=0)
    ap.add_argument("--finish-on-signal", action="store_true", help="по первому сигналу дописать текущий случай (иначе бросить)")
    ap.add_argument("--check", action="store_true", help="status: код 0, только если набор готов")
    ap.add_argument("--out", default="")
    ap.add_argument("--json", action="store_true", help="status: сводка одной строкой JSON")
    ap.add_argument("--log", default="", help="подробный журнал — дописывать в этот файл, а не в stdout")
    ap.add_argument("--progress", action="store_true", help="run: обновляемая строка прогресса на stdout (\\r)")
    a = ap.parse_args(argv)
    global _LOG
    if a.log:
        Path(a.log).parent.mkdir(parents=True, exist_ok=True)
        _LOG = open(a.log, "a", encoding="utf-8")
    cfg = load_cfg(a.config)
    if a.dataset not in cfg["datasets"]:
        log(f"ОШИБКА: набора {a.dataset} нет в {a.config}")
        return EXIT_ERR
    L = Layout(cfg, data_root(a, cfg), a.dataset)
    if a.cmd == "path":
        print(L.dir)
        return EXIT_OK
    sys.path.insert(0, str(HERE))
    if a.cmd == "plan":
        return cmd_plan(cfg, L)
    if a.cmd == "run":
        return cmd_run(cfg, L, a)
    if a.cmd == "status":
        return cmd_status(cfg, L, a)
    return cmd_export(cfg, L, a)


if __name__ == "__main__":
    sys.exit(main())
