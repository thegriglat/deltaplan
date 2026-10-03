"""Модель-пустышка с двумя входами для теста AirOnnx (O2) и эталон ORT Python.

Как сеть O1 в миниатюре: входы `maps` [1, 3, 12, 12] и `nums` [1, 5] (FiLM), выходы `out` [1, 2, 12, 12]
и `aux` [1, 2] (второй выход — проверить, что run() отдаёт все выходы). ONNX opset 17, float32,
веса детерминированные (seed 7), metadata_props — две строки (одна не-ASCII: проверка UTF-8).
Входы — формулы (тест в Godot строит их сам), i — плоский индекс в порядке C:
  maps[i] = float32(fmod(i * 0.6180339887, 1.0) * 2 - 1)
  nums[i] = float32(fmod(i * 0.4142135623 + 0.3, 1.0) * 2 - 1)
Пишет рядом:
  dummy_two_inputs.onnx — модель;
  dummy_two_inputs_ref.bin — эталон ORT Python (intra-op потоки = 1): out, затем aux; float32 little-endian.
Запуск: CUDA_VISIBLE_DEVICES= /home/greg/deltaplan-air-nn/tools/research/air_nn_pilot/.venv/bin/python -B make_dummy_model.py
"""
import os

import numpy as np
import onnx
import onnxruntime as ort
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
C_IN, C_OUT, H, W, N_NUM = 3, 2, 12, 12, 5
META = {"deltaplan.test": "двухвходовая пустышка", "deltaplan.agl": "10,20,40"}


class Dummy(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.c1 = torch.nn.Conv2d(C_IN, 8, 3, padding=1)
        self.c2 = torch.nn.Conv2d(8, C_OUT, 3, padding=1)
        self.film = torch.nn.Linear(N_NUM, 2 * C_OUT)

    def forward(self, maps, nums):
        h = self.c2(torch.nn.functional.gelu(self.c1(maps)))
        g = self.film(nums)
        scale = g[:, :C_OUT, None, None]
        shift = g[:, C_OUT:, None, None]
        out = h * (1 + torch.tanh(scale)) + shift
        return out, out.mean(dim=(2, 3))


def inputs():
    i = np.arange(C_IN * H * W, dtype=np.float64)
    maps = (np.fmod(i * 0.6180339887, 1.0) * 2.0 - 1.0).astype(np.float32).reshape(1, C_IN, H, W)
    j = np.arange(N_NUM, dtype=np.float64)
    nums = (np.fmod(j * 0.4142135623 + 0.3, 1.0) * 2.0 - 1.0).astype(np.float32).reshape(1, N_NUM)
    return maps, nums


def main():
    torch.manual_seed(7)
    m = Dummy().eval()
    path = os.path.join(HERE, "dummy_two_inputs.onnx")
    torch.onnx.export(m, (torch.zeros(1, C_IN, H, W), torch.zeros(1, N_NUM)), path, opset_version=17,
                      input_names=["maps", "nums"], output_names=["out", "aux"], dynamo=False)
    mp = onnx.load(path)
    for k, v in META.items():
        mp.metadata_props.add(key=k, value=v)
    onnx.checker.check_model(mp)
    onnx.save(mp, path)

    maps, nums = inputs()
    so = ort.SessionOptions()
    so.intra_op_num_threads = 1
    s = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
    out, aux = s.run(["out", "aux"], {"maps": maps, "nums": nums})
    with torch.no_grad():
        to, ta = m(torch.from_numpy(maps), torch.from_numpy(nums))
    print("ORT", ort.__version__, "out", out.shape, "aux", aux.shape,
          "max|ORT-torch| =", float(max(np.abs(out - to.numpy()).max(), np.abs(aux - ta.numpy()).max())))
    print("meta", s.get_modelmeta().custom_metadata_map)
    ref = os.path.join(HERE, "dummy_two_inputs_ref.bin")
    with open(ref, "wb") as f:
        f.write(out.astype("<f4").tobytes() + aux.astype("<f4").tobytes())
    print("model", os.path.getsize(path), "B; ref", os.path.getsize(ref), "B")


if __name__ == "__main__":
    main()
