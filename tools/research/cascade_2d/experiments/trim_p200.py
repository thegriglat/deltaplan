"""CSD-4: P200 без верхней строки клеток (nz 2n-1 вместо 2n) — старт каскада от 200 м.
Сетки CSD-1 имеют nz_k = 2·nz_{k-1} (26, 52, 102, 202, 402), а каскад (F0, CSD-3) требует
ребёнку 2·nz_parent − 1 строк. От P400 это обрезка геометрии ребёнка; от P200 (52 -> 103 > 102)
не проходит. Срезаем верхнюю строку P200 (z ~ 2,5 км, губка): дивергенция остальных клеток не меняется.
Пишет $DATA/fields_p200t/<C>/picard_none_d200.{json,bin}."""
import os, sys
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "contract"))
from cascade2d_io import read_f1, write_f1, data_dir
for C in ["C0", "C1", "C2", "C3", "C4"]:
    src = os.path.join(data_dir(), "fields", C, "picard_none_d200.json")
    meta, a = read_f1(src)
    nz = meta["nz"] - 1
    b = dict(u=a["u"][:nz], w=a["w"][:nz + 1], th=a["th"][:nz], cell=a["cell"][:nz],
             tu=a["tu"][:nz], tw=a["tw"][:nz + 1], h=a["h"])
    m = {k: v for k, v in meta.items() if k not in ("arrays", "created")}
    m["nz"] = nz
    write_f1(os.path.join(data_dir(), "fields_p200t", C, "picard_none_d200.json"), m, b)
    print(C, "nz", meta["nz"], "->", nz)
