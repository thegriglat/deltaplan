"""χ² Askervein (47 наблюдаемых перекалибровки: 39 разгонов AM-09 + 8 точек профиля RS) прямо по строкам
runs-файла recal (без интерполяции) — рецепт приёмки А1 (4): правки не должны трогать нейтральный Askervein.

  PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
  $PY askervein_chi2.py [../recal/out/runs_check25.jsonl]
Опорное: check25 (λ/h 0,0307, α 0,2346, z0 0,09) — χ² 68,15 (docs/air_model_tune.md, «Перекалибровка»).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "recal"))
import fit as F          # noqa: E402  (D, SIG, CORR, GRP, obs_vec — из config.json, fit_s1.json, данных RS)


def chi2_of(r):
    terms = ((F.obs_vec(r) + F.CORR - F.D) / F.SIG) ** 2
    return float(terms.sum()), F.groups(terms), terms


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE.parent / "recal" / "out" / "runs_check25.jsonl"
    out = []
    for line in path.read_text().splitlines():
        r = json.loads(line)
        if "obs" not in r:
            out.append(dict(status=r.get("status"), err=r.get("err")))
            continue
        c, g, _ = chi2_of(r)
        out.append(dict(lam_frac=r["lam_frac"], alpha=r["alpha"], z0=r["z0"], dx=r["dx"], status=r["status"],
                        iters=r.get("iters"), chi2=round(c, 2), ndf=len(F.NAMES) - 3,
                        groups={k: round(v["chi2"], 2) for k, v in g.items()}))
    print(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
