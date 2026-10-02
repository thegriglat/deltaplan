#!/usr/bin/env python3
"""Экспорт/осмотр .onnx сети области по контракту O1 (docs/contracts/air-onnx.md).

  --ckpt <прогон>/main --out m.onnx   из ckpt/best.pt + task.json (как evaluate.load_net) + метаданные O1
  --random --channels 8,16 --maps 9 --seed 0 --out m.onnx   малая случайная сеть (тесты игры)
  --info файл.onnx                     входы, выходы, метаданные
  --verify файл.onnx                   O1-проверка + сверка с эталоном `<файл без .onnx>_ref.json` (если есть)
  --make-ref файл.onnx                 записать эталон ORT на детерминированном входе (см. README)

Запуск — только CPU, venv пилота (только читать): CUDA_VISIBLE_DEVICES= .../air_nn_pilot/.venv/bin/python -B
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "tools/research/air_nn_pilot"))
sys.path.insert(0, str(HERE))

import numpy as np  # noqa: E402

GRID, NUMS, NOUT = 96, 18, 91
P2_VERSION = {4: "2", 9: "4"}
# точки выборки эталона: (канал, i, j) — формула в README
REF_POINTS = [((7 * k + 3) % NOUT, (13 * k + 5) % GRID, (29 * k + 11) % GRID) for k in range(64)]


def ref_input(n_maps: int):
    """Детерминированный вход (формула — README): maps[0,c,i,j] = sin(0.07 i + 0.11 j + 0.5 c),
    nums[0,k] = cos(0.3 k + 0.2). float32 (формулы считаются в float64, затем приведение)."""
    c = np.arange(n_maps)[:, None, None]
    i = np.arange(GRID)[None, :, None]
    j = np.arange(GRID)[None, None, :]
    X = np.sin(0.07 * i + 0.11 * j + 0.5 * c)[None].astype(np.float32)
    F = np.cos(0.3 * np.arange(NUMS) + 0.2)[None].astype(np.float32)
    return X, F


def write_meta(path: Path, n_maps: int, source: str, domain=None):
    import onnx
    from pilotnn import prep as P
    m = onnx.load(str(path))
    meta = {
        "deltaplan.p2_version": P2_VERSION[n_maps],
        "deltaplan.map_names": ",".join(P.MAP_NAMES[:n_maps]),
        "deltaplan.film_names": ",".join(P.FILM_NAMES),
        "deltaplan.agl": ",".join(str(a) for a in P.AGL),
        "deltaplan.source": source,
    }
    if domain is not None:
        meta["deltaplan.domain"] = json.dumps(domain, ensure_ascii=False)
    del m.metadata_props[:]
    for k, v in meta.items():
        p = m.metadata_props.add()
        p.key, p.value = k, v
    onnx.save(m, str(path))


def export_net(net, n_maps, path: Path, source, domain=None, seed=0):
    from pilotnn import evaluate as E
    X, F = ref_input(n_maps)
    res = E.export_onnx(net, X, F, path, 1, [1])
    write_meta(path, n_maps, source, domain)
    return res


def cmd_ckpt(a):
    import torch
    from pilotnn import evaluate as E
    run = Path(a.ckpt)
    net, task = E.load_net(run, torch.device("cpu"))
    n_maps = net.inp.conv.weight.shape[1]
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    res = export_net(net, n_maps, out, f"{run.resolve()} (ckpt/best.pt)", task.get("domain"))
    print(json.dumps({k: res[k] for k in ("size_mb", "ort_vs_torch_max_abs", "ort_vs_torch_ok")}))
    return 0 if res["ort_vs_torch_ok"] else 1


def build_random(channels, n_maps, seed, emb):
    import torch
    from pilotnn import model as M
    torch.manual_seed(seed)
    net = M.build({"channels": channels, "emb": emb}, n_maps, NUMS, NOUT)
    with torch.no_grad():
        for mod in net.modules():
            if isinstance(mod, M.FiLMBlock):   # нулевая инициализация FiLM скрыла бы вход nums — взять ненулевую
                torch.nn.init.normal_(mod.film.weight, 0, 0.3)
                torch.nn.init.normal_(mod.film.bias, 0, 0.1)
        g = torch.Generator().manual_seed(seed + 1)
        net.out_scale.copy_(0.2 + torch.rand(NOUT, generator=g))
    return net.eval()


def cmd_random(a):
    chans = [int(x) for x in a.channels.split(",")]
    net = build_random(chans, a.maps, a.seed, a.emb)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    res = export_net(net, a.maps, out, f"random seed={a.seed} channels={a.channels} emb={a.emb}")
    print(json.dumps({k: res[k] for k in ("size_mb", "ort_vs_torch_max_abs", "ort_vs_torch_ok")}))
    return 0 if res["ort_vs_torch_ok"] else 1


def cmd_info(a):
    import onnx
    m = onnx.load(a.info, load_external_data=False)
    init = {i.name for i in m.graph.initializer}

    def sh(v):
        return [d.dim_value if d.HasField("dim_value") else d.dim_param for d in v.type.tensor_type.shape.dim]

    print("opset:", {o.domain or "ai.onnx": o.version for o in m.opset_import})
    for v in m.graph.input:
        if v.name not in init:
            print(f"вход  {v.name}: {sh(v)} {onnx.TensorProto.DataType.Name(v.type.tensor_type.elem_type)}")
    for v in m.graph.output:
        print(f"выход {v.name}: {sh(v)} {onnx.TensorProto.DataType.Name(v.type.tensor_type.elem_type)}")
    print("размер, байт:", Path(a.info).stat().st_size)
    if not m.metadata_props:
        print("метаданные: нет (необязательны, O1)")
    for p in m.metadata_props:
        print(f"{p.key} = {p.value}")
    return 0


def run_ort(path, X, F, threads=1):
    import onnxruntime as ort
    so = ort.SessionOptions()
    so.intra_op_num_threads = threads
    so.inter_op_num_threads = 1
    s = ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])
    return s.run(None, dict(maps=X, nums=F))[0]


def n_maps_of(path):
    import onnx
    m = onnx.load(str(path), load_external_data=False)
    init = {i.name for i in m.graph.initializer}
    v = [v for v in m.graph.input if v.name == "maps" and v.name not in init][0]
    return v.type.tensor_type.shape.dim[1].dim_value


def ref_path(path):
    p = Path(path)
    return p.with_name(p.stem + "_ref.json")


def cmd_make_ref(a):
    n = n_maps_of(a.make_ref)
    X, F = ref_input(n)
    o = run_ort(a.make_ref, X, F)
    ref = dict(
        input="maps[0,c,i,j]=sin(0.07*i+0.11*j+0.5*c); nums[0,k]=cos(0.3*k+0.2); float64 -> float32",
        n_maps=n, out_shape=list(o.shape),
        points_rule="k=0..63: c=(7k+3)%91, i=(13k+5)%96, j=(29k+11)%96",
        points=[dict(c=c, i=i, j=j, v=float(o[0, c, i, j])) for c, i, j in REF_POINTS],
        channel_mean=[float(x) for x in o[0].mean(axis=(1, 2))],
        channel_absmax=[float(x) for x in np.abs(o[0]).max(axis=(1, 2))],
        tol_abs=1e-4,
    )
    ref_path(a.make_ref).write_text(json.dumps(ref, indent=1))
    print("эталон:", ref_path(a.make_ref))
    return 0


def cmd_verify(a):
    from test_contract_o1 import check_file
    errs = check_file(a.verify)
    rp = ref_path(a.verify)
    if rp.exists():
        ref = json.loads(rp.read_text())
        X, F = ref_input(ref["n_maps"])
        o = run_ort(a.verify, X, F)
        d = max(abs(float(o[0, p["c"], p["i"], p["j"]]) - p["v"]) for p in ref["points"])
        d = max(d, float(np.max(np.abs(o[0].mean(axis=(1, 2)) - np.array(ref["channel_mean"])))))
        d = max(d, float(np.max(np.abs(np.abs(o[0]).max(axis=(1, 2)) - np.array(ref["channel_absmax"])))))
        print(f"эталон: макс. расхождение {d:.3g} (допуск {ref['tol_abs']})")
        if d > ref["tol_abs"]:
            errs.append(f"эталон: {d}")
    else:
        print("эталона нет:", rp)
    for e in errs:
        print("нарушение:", e)
    print("verify:", "OK" if not errs else "FAIL")
    return 1 if errs else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ckpt")
    ap.add_argument("--random", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("--channels", default="8,16")
    ap.add_argument("--maps", type=int, default=9, choices=[4, 9])
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--emb", type=int, default=16)
    ap.add_argument("--info")
    ap.add_argument("--verify")
    ap.add_argument("--make-ref", dest="make_ref")
    a = ap.parse_args()
    if a.info:
        return cmd_info(a)
    if a.verify:
        return cmd_verify(a)
    if a.make_ref:
        return cmd_make_ref(a)
    if a.ckpt and a.out:
        return cmd_ckpt(a)
    if a.random and a.out:
        return cmd_random(a)
    ap.error("нужно --ckpt/--random с --out, или --info/--verify/--make-ref")


if __name__ == "__main__":
    sys.exit(main())
