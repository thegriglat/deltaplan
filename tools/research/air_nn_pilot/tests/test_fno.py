"""Проверки U-FNO на CPU (venv .venv_fno): python tests/test_fno.py [--onnx]
1) SpecDFT == библиотечный SpectralConv (то же, что экспорт в ONNX); 2) формы и число параметров; 3) ONNX ≈ PyTorch."""
import sys, time, tempfile
from pathlib import Path
import numpy as np
import torch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pilotnn import model as M
from pilotnn.fno import SpecDFT, SpecBranch
from neuralop.layers.spectral_convolution import SpectralConv

torch.manual_seed(0)
for n, m in ((192, 24), (96, 20), (48, 16), (24, 12)):
    c = SpectralConv(6, 5, n_modes=(m, m), bias=False, fft_norm="forward")
    x = torch.randn(2, 6, n, n)
    with torch.no_grad():
        y = c(x); d = SpecDFT(c.weight.tensor, n, n)(x)
    print(f"SpecDFT vs SpectralConv n={n} modes={m}: max|Δ|={float((y - d).abs().max()):.2e}, max|y|={float(y.abs().max()):.2e}")
    assert float((y - d).abs().max()) < 1e-5 * max(1, float(y.abs().max()))

cfg = dict(arch="ufno", channels=[24, 48, 72, 96, 144], emb=128, spec_ch=24, modes=[24, 20, 16, 0, 0])
net = M.build(cfg, 9, 18, 91)
print("параметры:", M.n_params(net), "комплексных весов (вещ.):", sum(2 * p.numel() for p in net.parameters() if p.is_complex()))
x, f = torch.randn(2, 9, 96, 96), torch.randn(2, 18)
net.eval()
with torch.no_grad():
    y = net(x, f); ye = net.for_export()(x, f)
print("выход", tuple(y.shape), "torch vs DFT-копия:", float((y - ye).abs().max()))
assert y.shape == (2, 91, 96, 96)
if "--onnx" in sys.argv:
    import onnxruntime as ort
    e = net.for_export()
    p = Path(tempfile.mkdtemp()) / "m.onnx"
    torch.onnx.export(e, (x[:1], f[:1]), str(p), opset_version=17, input_names=["maps", "nums"], output_names=["out"], dynamo=False)
    print("ONNX МБ:", p.stat().st_size / 1e6)
    for th in (4, 1):
        so = ort.SessionOptions(); so.intra_op_num_threads = th
        s = ort.InferenceSession(str(p), so, providers=["CPUExecutionProvider"])
        o = s.run(None, dict(maps=x[:1].numpy(), nums=f[:1].numpy()))[0]
        ref = e(x[:1], f[:1]).detach().numpy()
        ts = []
        for _ in range(12):
            t0 = time.perf_counter(); s.run(None, dict(maps=x[:1].numpy(), nums=f[:1].numpy())); ts.append(time.perf_counter() - t0)
        print(f"ORT потоков {th}: max|Δ| {np.abs(o - ref).max():.2e}, медиана {np.median(ts) * 1000:.1f} мс")
print("ok")
