"""Модель-пустышка для пробника ORT <-> Godot (NN-7а) и эталон ORT Python.

Малый Conv-стек: вход [1, 4, 96, 96] float32 -> выход [1, 2, 96, 96] float32, ONNX opset 17.
Веса — детерминированные (seed 7). Вход — формула (тест в Godot строит его сам, хранить не нужно):
  x[i] = float32(fmod(i * 0.6180339887, 1.0) * 2 - 1), i — плоский индекс в порядке C.
Пишет рядом:
  dummy_conv.onnx  — модель;
  dummy_ref.bin    — эталонный выход ORT Python (intra-op потоки = 1): float32[2*96*96], little-endian.
Запуск: /home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python make_dummy_model.py
"""
import os

import numpy as np
import onnxruntime as ort
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
C_IN, C_OUT, H, W = 4, 2, 96, 96


class Dummy(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.c1 = torch.nn.Conv2d(C_IN, 16, 3, padding=1)
        self.c2 = torch.nn.Conv2d(16, 16, 3, padding=1)
        self.c3 = torch.nn.Conv2d(16, C_OUT, 1)

    def forward(self, x):
        h = torch.nn.functional.gelu(self.c1(x))
        h = torch.tanh(self.c2(h)) + h
        return self.c3(h)


def main():
    torch.manual_seed(7)
    m = Dummy().eval()
    path = os.path.join(HERE, "dummy_conv.onnx")
    x = torch.zeros(1, C_IN, H, W)
    torch.onnx.export(m, (x,), path, opset_version=17, input_names=["x"], output_names=["y"],
                      dynamo=False)
    i = np.arange(C_IN * H * W, dtype=np.float64)
    xin = (np.fmod(i * 0.6180339887, 1.0) * 2.0 - 1.0).astype(np.float32).reshape(1, C_IN, H, W)
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    s = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
    y = s.run(None, {"x": xin})[0].astype(np.float32)
    with torch.no_grad():
        yt = m(torch.from_numpy(xin)).numpy()
    print("ORT", ort.__version__, "out", y.shape, "max|ORT-torch| =", float(np.abs(y - yt).max()))
    with open(os.path.join(HERE, "dummy_ref.bin"), "wb") as f:
        f.write(y.astype("<f4").tobytes())
    print("model", os.path.getsize(path), "B; ref", os.path.getsize(os.path.join(HERE, "dummy_ref.bin")), "B")


if __name__ == "__main__":
    main()
