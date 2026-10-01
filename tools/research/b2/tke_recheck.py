"""Б2 (решение К2 п. 2): ТКЭ Askervein масштаба 3 (метод AM-09б: askervein_fields.py → turb_askervein.gd → fit_s3.py)
с λ/h 0,0158 и профилем притока Б1 (α 0,242, z0 0,05, max_profile по правилу z_sat). Поля — fields/ (вне git).

    PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
    cd tools/research/tune && flock /tmp/heat_ca_gpu.lock $PY ../b2/tke_recheck.py fields    # поля (~10 мин GPU)
    XDG_DATA_HOME=$(mktemp -d) godot --headless --path . -s tools/research/tune/turb_askervein.gd -- \
        --points=tools/research/tune/out/tke_points.json --out=tools/research/b2/out/tke/tke_model.json \
        tools/research/b2/fields/ask_12p5_best tools/research/b2/fields/ask_25_best \
        tools/research/b2/fields/ask_50a_best tools/research/b2/fields/ask_12p5_nom
    cd tools/research/tune && $PY ../b2/tke_recheck.py fit          # → ../b2/out/tke/fit_s3.json
"""
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TUNE = HERE.parent / "tune"
sys.path.insert(0, str(TUNE))
sys.path.insert(0, str(HERE.parent / "air3d"))
sys.path.insert(0, str(HERE.parent / "cases"))
import askervein_fields as AF  # noqa: E402
import askervein_runs as R  # noqa: E402
import rules as RU  # noqa: E402

ALPHA, Z0, LAM_FRAC, U10, F = 0.242, 0.05, 0.0158, 8.9, 1.22e-4   # Б1: α_A, z0_A; U10 и f — askervein_runs
OUT = HERE / "out" / "tke"


def fields():
    prm = dict(lam_frac=LAM_FRAC, z0=Z0, alpha=ALPHA, max_profile=RU.max_profile(ALPHA, U10, Z0, F))
    (HERE / "fields").mkdir(exist_ok=True)
    for name, dx, adv1 in (("ask_12p5_best", 12.5, False), ("ask_25_best", 25.0, False), ("ask_50a_best", 50.0, True)):
        res = R.run(prm, dx=dx, adv2=not adv1, keep=True)
        res["z0"] = Z0
        print(name, res["status"], res["iters"], f"{res['t']:.0f} с", flush=True)
        AF.export(res, HERE / "fields" / name)
        del res
    # fit_s3 ждёт и «номинал» — здесь тот же лучший (номинала отдельно нет)
    for ext in (".json", ".bin"):
        shutil.copy(HERE / "fields" / ("ask_12p5_best" + ext), HERE / "fields" / ("ask_12p5_nom" + ext))


def fit():
    import fit_s3 as S3
    OUT.mkdir(parents=True, exist_ok=True)
    shutil.copy(TUNE / "out" / "tke_points.json", OUT / "tke_points.json")
    S3.OUT = OUT
    S3.main()
    old = json.loads((TUNE / "out" / "fit_s3.json").read_text())
    new = json.loads((OUT / "fit_s3.json").read_text())
    print("номинал χ² AM-09б", round(old["nominal"]["chi2"], 1), "→ Б2", round(new["nominal"]["chi2"], 1))
    print("по группам AM-09б", {g: round(v["chi2"], 1) for g, v in old["groups"].items()})
    print("по группам Б2", {g: round(v["chi2"], 1) for g, v in new["groups"].items()})


if __name__ == "__main__":
    {"fields": fields, "fit": fit}[sys.argv[1]]()
