"""Скачивание ARCO-ERA5 (Google Cloud, анонимно): 2m_temperature -> суточный максимум/минимум по МЕСТНЫМ суткам ячейки 0.25°
(местные сутки = UTC + lon/15 ч), суммы по месяцам. Задача = (год, месяцы, шаг): шаг 3 ч (8 сроков в сутках, 00,03..21 UTC)
или 1 ч (24 срока; из них же 8-срочная выборка t%3==0 для поправки недобора). Сутки с неполным набором сроков (края задачи)
отбрасываются. Выход RAW/t2m/<год>_m<m0>-<m1>_s<шаг>.npz: tx8,tn8[nm,721,1440] (суммы максимума/минимума по дням 8 сроков), n8[nm,1440];
при шаге 1 ещё tx24,tn24,n24. Возобновляемо: готовая задача пропускается.
Запуск: python fetch.py <процессов> <потоков> [hourly_year=2015] 2020 2019 ...  (список 3-часовых лет)"""
import os, sys, time, datetime as dt
import numpy as np
from concurrent.futures import ThreadPoolExecutor
import zarr, gcsfs
from common import ARCO, RAW

OUT = os.path.expanduser(RAW) + "/t2m"
os.makedirs(OUT, exist_ok=True)
EPOCH = dt.datetime(1900, 1, 1)
LON = np.arange(1440) * 0.25
SHIFT = np.where(LON >= 180, LON - 360, LON) / 15.0  # ч


def hidx(d):
    return int((d - EPOCH).total_seconds() // 3600)


def fname(y, m0, m1, step):
    return f"{OUT}/{y}_m{m0:02d}-{m1:02d}_s{step}.npz"


class Acc:
    def __init__(self, nm, hourly):
        self.nm = nm; self.hourly = hourly
        self.tx8 = np.zeros((nm, 721, 1440)); self.tn8 = np.zeros_like(self.tx8); self.n8 = np.zeros((nm, 1440))
        if hourly:
            self.tx24 = np.zeros_like(self.tx8); self.tn24 = np.zeros_like(self.tx8); self.n24 = np.zeros((nm, 1440))
        self.live = {}  # локальный день -> dict

    def feed(self, t, f):
        ld = np.floor((t + SHIFT) / 24).astype(np.int64)
        for d in np.unique(ld):
            mk = ld == d
            st = self.live.get(d)
            if st is None:
                st = self.live[d] = {k: (np.full((721, 1440), -1e9 if k[:2] == "tx" else 1e9, np.float32)) for k in (("tx8", "tn8", "tx24", "tn24") if self.hourly else ("tx8", "tn8"))}
                st["c8"] = np.zeros(1440, int); st["c24"] = np.zeros(1440, int)
            sub = (t % 3 == 0)
            keys = [("tx8", "tn8", "c8")] if sub else []
            if self.hourly: keys.append(("tx24", "tn24", "c24"))
            for kx, kn, kc in keys:
                st[kx][:, mk] = np.maximum(st[kx][:, mk], f[:, mk]); st[kn][:, mk] = np.minimum(st[kn][:, mk], f[:, mk]); st[kc][mk] += 1
        for d in [d for d in self.live if d < ld.min()]:
            self.flush(d)

    def flush(self, d, y=None, m0=None, m1=None):
        st = self.live.pop(d)
        date = (EPOCH + dt.timedelta(days=int(d) - 0)).date() if False else (dt.date(1900, 1, 1) + dt.timedelta(days=int(d)))
        if date.year != self.y or not (self.m0 <= date.month <= self.m1):
            return
        k = date.month - self.m0
        for tag, full in (("8", 8), ("24", 24)):
            if tag == "24" and not self.hourly: continue
            ok = st["c" + tag] == full
            self.__dict__["tx" + tag][k][:, ok] += st["tx" + tag][:, ok]; self.__dict__["tn" + tag][k][:, ok] += st["tn" + tag][:, ok]
            self.__dict__["n" + tag][k][ok] += 1

    def finish(self):
        for d in sorted(self.live): self.flush(d)


def do_task(args):
    y, m0, m1, step, nthr = args
    fn = fname(y, m0, m1, step)
    if os.path.exists(fn):
        return fn
    fs = gcsfs.GCSFileSystem(token="anon", timeout=60, requests_timeout=60)
    a = zarr.open_consolidated(fs.get_mapper(ARCO), mode="r")["2m_temperature"]
    start = dt.datetime(y, m0, 1) - dt.timedelta(days=1)
    end = (dt.datetime(y + (m1 == 12), m1 % 12 + 1, 1)) + dt.timedelta(days=1)
    h0 = hidx(start); h1 = hidx(end)
    h0 += (-h0) % step
    times = list(range(h0, h1, step))
    acc = Acc(m1 - m0 + 1, step == 1); acc.y = y; acc.m0 = m0; acc.m1 = m1

    def get(t):
        for att in range(8):
            try:
                return a[t].astype(np.float32)
            except Exception:
                time.sleep(2 + 3 * att)
        raise RuntimeError(f"не скачалось {t}")

    t0 = time.time()
    with ThreadPoolExecutor(nthr) as ex:
        for b in range(0, len(times), 4 * nthr):
            blk = times[b:b + 4 * nthr]
            for t, f in zip(blk, ex.map(get, blk)):
                acc.feed(t, f - 273.15)
    acc.finish()
    d = dict(tx8=acc.tx8, tn8=acc.tn8, n8=acc.n8)
    if acc.hourly: d.update(tx24=acc.tx24, tn24=acc.tn24, n24=acc.n24)
    np.savez(fn + ".tmp.npz", **d)
    os.replace(fn + ".tmp.npz", fn)
    print(os.path.basename(fn), "ok", round(time.time() - t0), "с", len(times), "сроков", flush=True)
    return fn


def tasks(hy, years, nthr):
    ts = [(hy, m, m, 1, nthr) for m in range(1, 13)]
    for y in years:
        ts += [(y, q, q + 2, 3, nthr) for q in (1, 4, 7, 10)]
    return ts


if __name__ == "__main__":
    npr, nthr, hy = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    years = [int(v) for v in sys.argv[4:]]
    from multiprocessing import Pool
    with Pool(npr) as p:
        for r in p.imap_unordered(do_task, tasks(hy, years, nthr), chunksize=1):
            pass
