"""upper_air_climatology.npz -> data/climate/upper_air_1deg.bin (формат HH2 v1, docs/contracts/haze-humidity.md).
Запуск: python bake.py [выход.bin]"""
import os, struct, sys
import numpy as np
import brotli
from common import RAW

R = os.path.expanduser(RAW)
c = np.load(f"{R}/upper_air_climatology.npz")
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../../data/climate/upper_air_1deg.bin")
out = os.path.abspath(out)
T_SCALE, T_OFF, Z_SCALE, Z_OFF = 0.01, -15.0, 0.1, 2000.0  # T: -15±327 °C; Z: 2000..5276 м, шаг 0.1 м
t, z = c["t"], c["z"]
tq = np.round((t - T_OFF) / T_SCALE); zq = np.round((z - Z_OFF) / Z_SCALE)
assert tq.min() > -32768 and tq.max() < 32768 and zq.min() > -32768 and zq.max() < 32768
tq = tq.astype("<i2"); zq = zq.astype("<i2")
assert tq.shape == zq.shape == (12, 180, 360)
raw = tq.tobytes() + zq.tobytes()
assert len(raw) == 2 * (2 * 12 * 180 * 360)
comp = brotli.compress(raw, quality=11, lgwin=24)
y0, y1 = (int(v) for v in c["years"])
hdr = b"HHUA" + struct.pack("<HHHHHH", 1, 1, 360, 180, 12, 700) + struct.pack("<ffffffff", -179.5, -89.5, 1.0, 1.0, T_SCALE, T_OFF, Z_SCALE, Z_OFF)
hdr += struct.pack("<IIII", len(raw), len(comp), y0, y1)
assert len(hdr) == 64, len(hdr)
os.makedirs(os.path.dirname(out), exist_ok=True)
tmp = out + ".tmp"
open(tmp, "wb").write(hdr + comp)
os.replace(tmp, out)
print(out, 64 + len(comp), "байт; raw", len(raw), "T", t.min(), t.max(), "Z", z.min(), z.max())
