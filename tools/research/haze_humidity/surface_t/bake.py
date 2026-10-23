"""RAW/climatology_t.npz -> data/climate/surface_t_1deg.bin (формат HH5 v1, docs/contracts/haze-humidity.md). Запуск: python bake.py [выход.bin]"""
import os, struct, sys
import numpy as np
import brotli
from common import RAW

c = np.load(os.path.expanduser(RAW) + "/climatology_t.npz")
out = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../../data/climate/surface_t_1deg.bin"))
TX_SCALE, TX_OFF, DTR_SCALE = 0.01, 0.0, 0.01
tx = np.clip(c["tx"], -69.9, 54.9); dtr = np.clip(c["dtr"], 0, 29.9)
txq = np.round((tx - TX_OFF) / TX_SCALE).astype("<i2"); dtq = np.round(dtr / DTR_SCALE).astype("<i2")
assert txq.shape == (12, 180, 360) == dtq.shape
print("клиппинг: tx", int((c["tx"] != tx).sum()), "dtr", int((c["dtr"] != dtr).sum()))
raw = txq.tobytes() + dtq.tobytes()
assert len(raw) == 2 * (2 * 12 * 180 * 360)
comp = brotli.compress(raw, quality=11, lgwin=24)
y0, y1 = (int(v) for v in c["years"])
hdr = b"HHST" + struct.pack("<HHHHHH", 1, 1, 360, 180, 12, 24) + struct.pack("<ffffffff", -179.5, -89.5, 1.0, 1.0, TX_SCALE, TX_OFF, DTR_SCALE, 0.0)
hdr += struct.pack("<IIII", len(raw), len(comp), y0, y1)
assert len(hdr) == 64, len(hdr)
os.makedirs(os.path.dirname(out), exist_ok=True)
tmp = out + ".tmp"
open(tmp, "wb").write(hdr + comp)
os.replace(tmp, out)
print(out, 64 + len(comp), "байт; raw", len(raw), "tx", tx.min(), tx.max(), "dtr", dtr.min(), dtr.max())
