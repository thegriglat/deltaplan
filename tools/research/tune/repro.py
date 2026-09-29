"""AM-09: повторный прогон с найденными параметрами (Askervein, 12,5 м + 2-й порядок, λ/h = 0,25,
z0 = 0,042 — прогон выгрузки поля fields/ask_12p5_best) против измерений и против предсказания
суррогата: тянет ли решатель то, что обещали полиномы, и попадает ли в эталон в пределах σ.

  .venv/bin/python repro.py → out/repro.json
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

import fit_s1 as F

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"


def main():
    runs = F.load(OUT / "runs_s1_25.jsonl") + F.load(OUT / "runs_ext_25.jsonl")
    fine = F.load(OUT / "runs_s1_12p5.jsonl")
    dom = F.load(OUT / "runs_dom_25.jsonl")
    fit = F.Fit(runs, fine, dom=dom)
    out = {}
    for tag in ("best", "nom"):
        r = json.loads((HERE / f"fields/ask_12p5_{tag}.obs.json").read_text())
        lf, z0 = r["params"]["lam_frac"], r["params"]["z0"]
        y = np.array([r["obs"][n] for n in fit.names]) + fit.dom           # прогон 12,5 м + поправка области
        sig = np.sqrt(fit.sd ** 2 + fit.sig_grid ** 2 + fit.sig_dom ** 2)
        pull = (y - fit.d) / sig
        pred = fit.model(lf, z0)
        out[tag] = dict(lam_frac=lf, z0=z0, iters=r["iters"], t=r["t"], chi2=float((pull ** 2).sum()), n=len(pull),
                        within1=int((np.abs(pull) < 1).sum()), within2=int((np.abs(pull) < 2).sum()),
                        surrogate_vs_run_rms=float(np.sqrt(np.mean((pred - y) ** 2))),
                        surrogate_vs_run_max=float(np.max(np.abs(pred - y))),
                        HT10=dict(run=float(r["obs"]["HT"]), with_dom=float(y[fit.names.index("HT")]), data=float(fit.d[fit.names.index("HT")])),
                        pulls=dict(zip(fit.names, pull.round(2).tolist())))
        print(tag, {k: v for k, v in out[tag].items() if k != "pulls"})
    (OUT / "repro.json").write_text(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
