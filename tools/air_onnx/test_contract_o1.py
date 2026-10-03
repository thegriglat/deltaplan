#!/usr/bin/env python3
"""Контрактный тест O1 (docs/contracts/air-onnx.md): формат .onnx сети области, который выдаёт пилот air-nn
(pilotnn/evaluate.py:export_onnx), против того, что читает игра.

Ломается, если в коде пилота (после `git merge feature/air-nn`) поменялись имена/порядок карт и чисел FiLM, высоты,
состав выхода, имена входов/выхода ONNX или opset — без правки контракта O1.

Запуск (только CPU, venv пилота — только читать, ничего в него не ставить):
  CUDA_VISIBLE_DEVICES= /home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python \
      tools/air_onnx/test_contract_o1.py [--model путь.onnx ...]
--model — дополнительно проверить готовые файлы (например main/model.onnx пилота) по O1. Итог — строка «O1: OK».
"""
from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

os.environ.setdefault("CUDA_VISIBLE_DEVICES", "")
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/research/air_nn_pilot"))

import numpy as np  # noqa: E402

# --- O1 v1: то, что читает игра ------------------------------------------------------------------------------
MAP_NAMES_V4 = ("terrain", "heat_flux", "x", "y", "slope_along", "slope_cross", "tpi_2k", "tpi_8k", "shelter")
MAP_NAMES_V2 = MAP_NAMES_V4[:4]      # сеть первого пилота (П2 v2) — первые 4 карты v4, формулы те же
FILM_NAMES = ("U10", "cos_r", "sin_r", "alpha", "max_profile", "z_i", "z_lcl", "sun_el", "sun_x", "sun_y", "heat",
              "t_max", "stab", "cap_flag", "cap_agl", "hour", "brk", "t_air")
AGL = (25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000)
N_MECH, N_HEAT = 3, 4
GRID = 96
OPSET = 17
INPUTS = {"maps": ({len(MAP_NAMES_V2), len(MAP_NAMES_V4)}, GRID), "nums": len(FILM_NAMES)}
OUTPUT = ("out", (1, (N_MECH + N_HEAT) * len(AGL), GRID, GRID))


def check_file(path) -> list[str]:
    """Проверка готового .onnx по O1; → список нарушений (пусто — соответствует)."""
    import onnx
    m = onnx.load(str(path), load_external_data=False)
    errs = []
    opsets = {o.domain: o.version for o in m.opset_import}
    if opsets.get("", opsets.get("ai.onnx")) != OPSET:
        errs.append(f"opset {opsets} ≠ {OPSET}")
    init = {i.name for i in m.graph.initializer}
    ins = {v.name: v for v in m.graph.input if v.name not in init}
    outs = {v.name: v for v in m.graph.output}

    def shape(v):
        return tuple(d.dim_value if d.HasField("dim_value") else d.dim_param for d in v.type.tensor_type.shape.dim)

    def is_f32(v):
        return v.type.tensor_type.elem_type == onnx.TensorProto.FLOAT

    if set(ins) != {"maps", "nums"}:
        errs.append(f"входы {sorted(ins)} ≠ ['maps', 'nums']")
    else:
        sm, sn = shape(ins["maps"]), shape(ins["nums"])
        if not (len(sm) == 4 and sm[0] == 1 and sm[1] in INPUTS["maps"][0] and sm[2:] == (GRID, GRID)):
            errs.append(f"maps {sm} ≠ (1, 4|9, 96, 96)")
        if sn != (1, INPUTS["nums"]):
            errs.append(f"nums {sn} ≠ (1, 18)")
        if not (is_f32(ins["maps"]) and is_f32(ins["nums"])):
            errs.append("входы не float32")
    if list(outs) != [OUTPUT[0]]:
        errs.append(f"выходы {list(outs)} ≠ ['out']")
    elif shape(outs["out"]) != OUTPUT[1] or not is_f32(outs["out"]):
        errs.append(f"out {shape(outs['out'])} ≠ {OUTPUT[1]} float32")
    meta = {p.key: p.value for p in m.metadata_props}
    if "deltaplan.p2_version" in meta and meta["deltaplan.p2_version"] not in ("2", "3", "4"):
        errs.append(f"deltaplan.p2_version = {meta['deltaplan.p2_version']}")
    return errs


def check_pilot_code() -> list[str]:
    """Константы и экспорт кода пилота = O1."""
    from pilotnn import prep as P
    errs = []
    if tuple(P.MAP_NAMES) != MAP_NAMES_V4:
        errs.append(f"prep.MAP_NAMES {P.MAP_NAMES}")
    if tuple(P.FILM_NAMES) != FILM_NAMES:
        errs.append(f"prep.FILM_NAMES {P.FILM_NAMES}")
    if tuple(P.AGL) != AGL or (P.N_MECH, P.N_HEAT) != (N_MECH, N_HEAT):
        errs.append(f"prep.AGL/N_MECH/N_HEAT {P.AGL} {P.N_MECH} {P.N_HEAT}")
    consts = dict(NORM_TERRAIN_M=1000.0, NORM_HEAT_WM2=800.0, NORM_SLOPE=0.3, TPI_SIGMAS_M=(2000.0, 8000.0),
                  NORM_TPI_M=(300.0, 1000.0), SX_STEP_M=200.0, SX_MAX_M=4000.0, NORM_SX_RAD=0.3, Z0=0.1)
    for k, v in consts.items():
        if getattr(P, k) != v:
            errs.append(f"prep.{k} = {getattr(P, k)} ≠ {v} (O1/O3 — константы карт)")
    import torch
    from pilotnn import evaluate as E
    from pilotnn import model as M
    torch.manual_seed(0)
    net = M.build({"channels": [8, 16], "emb": 16}, len(MAP_NAMES_V4), len(FILM_NAMES), OUTPUT[1][1])
    rng = np.random.default_rng(0)
    X = rng.standard_normal((1, len(MAP_NAMES_V4), GRID, GRID)).astype(np.float32)
    F = rng.standard_normal((1, len(FILM_NAMES))).astype(np.float32)
    with tempfile.TemporaryDirectory() as d:
        path = Path(d) / "model.onnx"
        res = E.export_onnx(net, X, F, path, 1, [1])
        if not res.get("ort_vs_torch_ok"):
            errs.append(f"ORT ≠ torch: {res.get('ort_vs_torch_max_abs')}")
        errs += [f"экспорт пилота: {e}" for e in check_file(path)]
    return errs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", action="append", default=[], help="готовый .onnx для проверки по O1")
    a = ap.parse_args()
    errs = check_pilot_code()
    for p in a.model:
        e = check_file(p)
        print(f"{p}: {'OK' if not e else '; '.join(e)}")
        errs += [f"{p}: {x}" for x in e]
    for e in errs:
        print("нарушение O1:", e)
    print("O1: OK" if not errs else f"O1: FAIL ({len(errs)})")
    sys.exit(1 if errs else 0)


if __name__ == "__main__":
    main()
