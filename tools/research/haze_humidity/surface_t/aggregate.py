"""RAW/t2m/*.npz -> RAW/climatology_t.npz: TX, DTR (по месяцам; 1° и 0.25°), поправка недобора, Z/lsm из HH-1 (climatology.npz).
Год входит, если есть все его задачи (3 ч: 4 квартала; часовой год: 12 месяцев). Поправка недобора (8 сроков -> 24 срока)
считается по часовому году по ячейке-месяцу 0.25° и добавляется ко всем годам. Запуск: python aggregate.py <часовой_год>"""
import glob, os, sys
import numpy as np
from common import RAW, to_1deg

R = os.path.expanduser(RAW)
hy = int(sys.argv[1]) if len(sys.argv) > 1 else 2015
files = glob.glob(f"{R}/t2m/*.npz")
by = {}
for f in files:
    b = os.path.basename(f)
    y = int(b[:4]); m0 = int(b[6:8]); by.setdefault(y, []).append((m0, f))
years = sorted(y for y, v in by.items() if (y == hy and len(v) == 12) or (y != hy and len(v) == 4))
print("годы", years)
tx = np.zeros((12, 721, 1440)); tn = np.zeros_like(tx); n = np.zeros((12, 1440))
tx24 = np.zeros_like(tx); tn24 = np.zeros_like(tx); n24 = np.zeros((12, 1440))
for y in years:
    for m0, f in sorted(by[y]):
        d = np.load(f)
        k = d["tx8"].shape[0]
        sl = slice(m0 - 1, m0 - 1 + k)
        tx[sl] += d["tx8"]; tn[sl] += d["tn8"]; n[sl] += d["n8"]
        if "tx24" in d:
            tx24[sl] += d["tx24"]; tn24[sl] += d["tn24"]; n24[sl] += d["n24"]
assert (n > 20 * len(years)).all(), n.min()
tx8 = tx / n[:, None, :]; tn8 = tn / n[:, None, :]
# поправка по часовому году: его же 8-срочные суммы -> разность 24-срочных и 8-срочных средних
hf = [f for m0, f in sorted(by[hy])]
sx8 = np.zeros_like(tx); sn8 = np.zeros_like(tx); nn = np.zeros((12, 1440))
for m0, f in sorted(by[hy]):
    d = np.load(f); sx8[m0 - 1] = d["tx8"][0]; sn8[m0 - 1] = d["tn8"][0]; nn[m0 - 1] = d["n8"][0]
h_tx8 = sx8 / nn[:, None, :]; h_tn8 = sn8 / nn[:, None, :]
h_tx24 = tx24 / n24[:, None, :]; h_tn24 = tn24 / n24[:, None, :]
c_tx = h_tx24 - h_tx8   # >= 0 : недобор максимума
c_tn = h_tn24 - h_tn8   # <= 0 : недобор минимума
TX = tx8 + c_tx
DTR = (tx8 - tn8) + (c_tx - c_tn)
TX1 = np.stack([to_1deg(TX[m]) for m in range(12)]); DTR1 = np.stack([to_1deg(DTR[m]) for m in range(12)])
cx1 = np.stack([to_1deg(c_tx[m]) for m in range(12)]); cn1 = np.stack([to_1deg(c_tn[m]) for m in range(12)])
c = np.load(f"{R}/climatology.npz")
np.savez(f"{R}/climatology_t.npz", tx=TX1, dtr=DTR1, tx025=TX.astype(np.float32), dtr025=DTR.astype(np.float32), ctx1=cx1, ctn1=cn1,
         z=c["z"], lsm=c["lsm"], z025=c["z025"], lsm025=c["lsm025"], years=np.array([min(years), max(years)]), nyears=len(years))
print("TX", TX1.min(), TX1.max(), "DTR", DTR1.min(), DTR1.max(), "поправка TX мин/сред/макс", cx1.min(), cx1.mean(), cx1.max(),
      "TN", cn1.min(), cn1.mean(), cn1.max())
