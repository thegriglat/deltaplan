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


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--weights", required=True)
    ap.add_argument("--cache", nargs="+", required=True, help="любой кеш — берутся 3 случая для проверки ORT = PyTorch")
    ap.add_argument("--out", default=str(HERE / "out"))
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    model, ck = E.load_model(a.weights)
    c = D.Cache(a.cache)
    X, F = c.load_xf(np.arange(min(3, len(c))))
    path = out / "model_hg.onnx"
    res = E.export_onnx(model, path, X, F, n_rep=20, threads=(4, 1),
                        meta={"deltaplan.p2_version": "4", "deltaplan.out_enc": "v4", "deltaplan.in_enc": "v4", "deltaplan.contract": "S7 v1",
                              "deltaplan.gstep": str(ck.get("gstep"))})
    io = E.onnx_io_match(path, REF)
    res.update(onnx_io_match=bool(io["match"]), io_new=io["new"], io_ref=io["ref"], weights=str(a.weights))
    (out / "onnx_report.json").write_text(json.dumps(res, indent=1, ensure_ascii=False))
    print(json.dumps({k: res[k] for k in ("size_mb", "ort_vs_torch_max_abs", "onnx_io_match", "time_ms")}))


if __name__ == "__main__":
    main()
