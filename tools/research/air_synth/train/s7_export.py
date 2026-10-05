"""S7 (SY-11): ONNX финальной сети (final.pt режима final) -> out/model_hg.onnx + отчёт out/onnx_report.json (совпадение интерфейса с
data/air_nn/model.onnx: имена, формы, типы; ORT = PyTorch; время ORT на CPU). Формат — как у пилота (pilotnn.evaluate.export_onnx, opset 17)."""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import s7_data as D  # noqa: E402
import s7_eval as E  # noqa: E402

REF = HERE.parents[3] / "data/air_nn/model.onnx"


CONDITIONS = ("hg_v2_hgw24", "game2_hgw24")   # S2 v4: таблицы условий набора (обучение + места игры)


def domain_from_conditions(root=None):
    """Область обучения для стража игры (AirNnInput.guard): min/max по таблицам условий, в единицах стража -> JSON-словарь."""
    import corpus_io as cio
    root = Path(root) if root else Path.home() / "air_synth_data/conditions"
    tabs = [cio.Conditions(str(root / n)).table for n in CONDITIONS]
    f = lambda k: [round(float(min(t[k].min() for t in tabs)), 2), round(float(max(t[k].max() for t in tabs)), 2)]  # noqa: E731
    return {"U10": f("u10_m_s"), "hour": f("hour_local"), "t_max": f("t_max_c")}


def add_domain(path, domain):
    """Дописывает deltaplan.domain в метаданные готового ONNX (граф не трогается)."""
    import onnx
    m = onnx.load(str(path))
    for p in [p for p in m.metadata_props if p.key == "deltaplan.domain"]:
        m.metadata_props.remove(p)
    e = m.metadata_props.add(); e.key, e.value = "deltaplan.domain", json.dumps(domain)
    onnx.save(m, str(path))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--weights")
    ap.add_argument("--add-domain", metavar="ONNX", help="только дописать deltaplan.domain (из таблиц условий) в готовый ONNX и выйти")
    ap.add_argument("--cache", nargs="+", help="любой кеш — берутся 3 случая для проверки ORT = PyTorch")
    ap.add_argument("--out", default=str(HERE / "out"))
    a = ap.parse_args()
    if a.add_domain:
        d = domain_from_conditions(); add_domain(a.add_domain, d); print(json.dumps(d)); return
    if not a.weights or not a.cache:
        ap.error("--weights и --cache обязательны")
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    model, ck = E.load_model(a.weights)
    c = D.Cache(a.cache)
    X, F = c.load_xf(np.arange(min(3, len(c))))
    path = out / "model_hg.onnx"
    res = E.export_onnx(model, path, X, F, n_rep=20, threads=(4, 1),
                        meta={"deltaplan.p2_version": "4", "deltaplan.out_enc": "v4", "deltaplan.in_enc": "v4", "deltaplan.contract": "S7 v1",
                              "deltaplan.gstep": str(ck.get("gstep")), "deltaplan.domain": json.dumps(domain_from_conditions())})
    io = E.onnx_io_match(path, REF)
    res.update(onnx_io_match=bool(io["match"]), io_new=io["new"], io_ref=io["ref"], weights=str(a.weights))
    (out / "onnx_report.json").write_text(json.dumps(res, indent=1, ensure_ascii=False))
    print(json.dumps({k: res[k] for k in ("size_mb", "ort_vs_torch_max_abs", "onnx_io_match", "time_ms")}))


if __name__ == "__main__":
    main()
