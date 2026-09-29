"""AM-09: слова пилота против модели ПОСЛЕ калибровки (в подгонку не входят).

Проверки synth.py (AM-01, reference.md → «1. Слова пилота — синтетика») с параметрами калибровки
(Params по умолчанию после AM-09) и, для сравнения, с λ/h = 0,1 (AM-01):
  4 — хребет H = L = 500 м: разгон на 2 H и 2,5 H над подножием;
  5 — седловина: скорость на 20/50 м над седлом к скорости перед склоном (пилот ×1,5 ± 0,2);
  6 — косой ветер 45°: w(45°)/w(0°) (пилот 0,55–0,8).

  flock /tmp/heat_ca_gpu.lock .venv/bin/python pilot_check.py → out/pilot_check.json
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "air3d"))

import air as A      # noqa: E402
import synth as SY   # noqa: E402

OUTD = HERE / "out" / "pilot"
OUTD.mkdir(parents=True, exist_ok=True)
SY.OUT = OUTD
_Params = A.Params


def with_lam_frac(lf):
    def make(**kw):
        kw.setdefault("lam_frac", lf)
        return _Params(**kw)
    return make


def main():
    res = {}
    for label, lf in (("am09", _Params().lam_frac), ("am01", 0.1)):
        A.Params = with_lam_frac(lf)
        SY.A.Params = A.Params
        row = dict(lam_frac=lf)
        c4 = SY.check4()
        row["ridge"] = {k: c4[k] for k in ("z2H", "z2.5H")}
        c5 = SY.check5()
        row["saddle"] = {a: {k: c5[a][k] for k in ("ratio_20", "ratio_50", "dir_dev_20")} for a in c5}
        c6 = SY.check6()
        row["oblique"] = {k: c6[k] for k in c6 if k.startswith("w45")}
        row["oblique"]["speedup20"] = [c6["a0"]["speedup_20"], c6["a45"]["speedup_20"]]
        res[label] = row
        (HERE / "out" / "pilot_check.json").write_text(json.dumps(res, ensure_ascii=False, indent=1, default=float))
    A.Params = _Params
    print(json.dumps(res, ensure_ascii=False, indent=1, default=float))


if __name__ == "__main__":
    main()
