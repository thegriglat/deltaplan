"""Скачивание ARCO-ERA5 (Google Cloud, анонимно): 2m_temperature -> суточный максимум/минимум по МЕСТНЫМ суткам ячейки 0.25°
(местные сутки = UTC + lon/15 ч) на ВЫБОРКЕ дней: SAMPLE_DAYS каждого месяца. Сроки: 3-часовые (8 в сутки, 00,03..21 UTC);
для часового года HY — 1 день (HDAY) в месяце всеми 24 сроками (поправка недобора: 24-срочный экстремум минус 8-срочный того же дня).
Для местных суток D (индекс дня от 1900-01-01) нужны UTC-часы [24D-12, 24D+36) -> 16 3-часовых срока (или 48 часовых).
Выход RAW/t2m/<год>_m<мм>_s<шаг>.npz: суммы по выбранным дням 8-срочных (и при шаге 1 — 24-срочных) max/min, их квадратов (для оценки
ошибки выборки) и число дней. Возобновляемо: готовая задача пропускается. Лог — flush.
Запуск: python fetch.py <потоков> <часовой_год> 2011 2012 ..."""
import os, sys, time, datetime as dt
import numpy as np
from concurrent.futures import ThreadPoolExecutor
import zarr, gcsfs
from common import ARCO, RAW

OUT = os.path.expanduser(RAW) + "/t2m"
os.makedirs(OUT, exist_ok=True)
EPOCH = dt.datetime(1900, 1, 1)
SAMPLE_DAYS = (1, 7, 13, 19, 25)
HDAY = 15
LON = np.arange(1440) * 0.25
SHIFT = np.where(LON >= 180, LON - 360, LON) / 15.0  # ч


def hidx(d):
    return int((d - EPOCH).total_seconds() // 3600)


def fname(y, m, step):
    return f"{OUT}/{y}_m{m:02d}_s{step}.npz"


def local_extremes(fields, hours, D, step):
    """fields: {час: (721,1440) °C}. Возвращает max/min по местным суткам D для сроков с шагом step (и подвыборки t%3==0)."""
    out = {}
    for tag, st in (("8", 3), ("24", 1)):
        if tag == "24" and step != 1:
            continue
        mx = np.full((721, 1440), -1e9, np.float32); mn = np.full((721, 1440), 1e9, np.float32); c = np.zeros(1440, int)
        for t in hours:
            if t % st:
                continue
            mk = np.floor((t + SHIFT) / 24).astype(np.int64) == D
            if not mk.any():
                continue
            f = fields[t]
            mx[:, mk] = np.maximum(mx[:, mk], f[:, mk]); mn[:, mk] = np.minimum(mn[:, mk], f[:, mk]); c[mk] += 1
        assert (c == int(tag)).all(), (tag, c.min(), c.max())
        out[tag] = (mx, mn)
    return out


def do_task(y, m, step, nthr, a):
    fn = fname(y, m, step)
    if os.path.exists(fn):
        return
    days = SAMPLE_DAYS if step == 3 else (HDAY,)
    acc = {}
    t0 = time.time(); nfetch = 0

    def get(t):
        for att in range(8):
            try:
                return a[t].astype(np.float32) - 273.15
            except Exception as e:
                print("повтор", t, type(e).__name__, flush=True); time.sleep(2 + 3 * att)
        raise RuntimeError(f"не скачалось {t}")

    for d in days:
        D = (dt.datetime(y, m, d) - EPOCH).days
        hours = [t for t in range(24 * D - 12, 24 * D + 36) if t % step == 0]
        with ThreadPoolExecutor(nthr) as ex:
            fields = dict(zip(hours, ex.map(get, hours)))
        nfetch += len(hours)
        for tag, (mx, mn) in local_extremes(fields, hours, D, step).items():
            for k, v in (("tx" + tag, mx), ("tn" + tag, mn), ("tx2" + tag, mx.astype(np.float64) ** 2)):
                acc[k] = acc.get(k, 0) + v.astype(np.float64)
        acc["nd"] = acc.get("nd", 0) + 1
    np.savez(fn + ".tmp.npz", **{k: (v.astype(np.float32) if k != "nd" else v) for k, v in acc.items()})
    os.replace(fn + ".tmp.npz", fn)
    print(os.path.basename(fn), "ok", round(time.time() - t0), "с", nfetch, "сроков", flush=True)


if __name__ == "__main__":
    nthr, hy = int(sys.argv[1]), int(sys.argv[2])
    years = [int(v) for v in sys.argv[3:]]
    fs = gcsfs.GCSFileSystem(token="anon", timeout=60, requests_timeout=60)
    a = zarr.open_consolidated(fs.get_mapper(ARCO), mode="r")["2m_temperature"]
    for m in range(1, 13):
        do_task(hy, m, 1, nthr, a)
    for y in years:
        for m in range(1, 13):
            do_task(y, m, 3, nthr, a)
    print("готово", flush=True)
