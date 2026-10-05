"""ONNX: имена, формы и типы входов/выходов нашей сети = data/air_nn/model.onnx (onnxruntime); значения ORT = PyTorch."""
from pathlib import Path

import numpy as np
import pytest
import torch

import s7_eval as E

REF = Path(__file__).resolve().parents[5] / "data/air_nn/model.onnx"


@pytest.mark.skipif(not REF.exists(), reason="нет data/air_nn/model.onnx")
def test_onnx_io_match(tmp_path):
    from pilotnn import model as M
    from s7_train import P2
    torch.manual_seed(0)
    m = M.build(P2["model"], 9, 18, 91)          # архитектура P2 без изменений (случайные веса — проверка интерфейса)
    m.out_scale.copy_(torch.rand(91) + 0.1)
    X = np.random.default_rng(0).normal(size=(2, 9, 96, 96)).astype(np.float32)
    F = np.random.default_rng(1).normal(size=(2, 18)).astype(np.float32)
    p = tmp_path / "m.onnx"
    res = E.export_onnx(m, p, X, F, n_rep=1, threads=(1,))
    assert res["ort_vs_torch_ok"]
    r = E.onnx_io_match(p, REF)
    assert r["match"], r
    assert [i[0] for i in r["new"]["inputs"]] == ["maps", "nums"] and r["new"]["outputs"][0][0] == "out"
    assert p.stat().st_size < 15e6
