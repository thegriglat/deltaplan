"""climatology.npz -> data/climate/dew_point_1deg.bin (формат HH1 v1, docs/contracts/haze-humidity.md).
Запуск: python bake.py [выход.bin]"""
import os, struct, sys
import numpy as np
import brotli
from common import RAW

R = os.path.expanduser(RAW)
c = np.load(f"{R}/climatology.npz")
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../../data/climate/dew_point_1deg.bin")
out = os.path.abspath(out)
TD_SCALE, TD_OFF, SD_SCALE, Z_SCALE = 0.01, 0.0, 0.01, 0.5
td = np.clip(c["td"], -79.9, 39.9)
sd = np.clip(c["sd"], 0, 19.9)
z = np.clip(c["z"], -499, 6999)
tdq = np.round((td - TD_OFF) / TD_SCALE).astype("<i2")
sdq = np.round(sd / SD_SCALE).astype("<i2")
zq = np.round(z / Z_SCALE).astype("<i2")
assert tdq.shape == (12, 180, 360) and sdq.shape == (12, 180, 360) and zq.shape == (180, 360)
print("клиппинг: td", int((c["td"] != td).sum()), "sd", int((c["sd"] != sd).sum()), "z", int((c["z"] != z).sum()))
raw = tdq.tobytes() + sdq.tobytes() + zq.tobytes()
assert len(raw) == 2 * (2 * 12 * 180 * 360 + 180 * 360)
comp = brotli.compress(raw, quality=11, lgwin=24)
y0, y1 = (int(v) for v in c["years"])
hdr = b"HHTD" + struct.pack("<HHHHHH", 1, 1, 360, 180, 12, 0) + struct.pack("<ffffffff", -179.5, -89.5, 1.0, 1.0, TD_SCALE, TD_OFF, SD_SCALE, Z_SCALE)
hdr += struct.pack("<IIII", len(raw), len(comp), y0, y1)
assert len(hdr) == 64, len(hdr)
os.makedirs(os.path.dirname(out), exist_ok=True)
tmp = out + ".tmp"
open(tmp, "wb").write(hdr + comp)
os.replace(tmp, out)
print(out, 64 + len(comp), "байт; raw", len(raw))
