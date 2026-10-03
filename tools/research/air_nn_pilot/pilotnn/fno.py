"""U-FNO для области 96² (опыт P3E7): U-Net P3E0 (те же блоки conv3×3 + GN + FiLM + обход) с параллельной
спектральной веткой FNO в блоках верхних уровней. Вход/выход/нормировки — как у P3E0 (карты (B, 9, 96, 96), FiLM 18
чисел, выход (B, 91, 96, 96) в единицах контракта П2; имена `inp.conv`, `emb.0`, `out_scale` — как у UNetFiLM).

Спектральная ветка (SpecBranch): свёртка 1×1 cin→cs (узкий канал спектральной части, чтобы уложиться в ~3 млн параметров),
спектральный слой `neuralop.layers.spectral_convolution.SpectralConv` (библиотека neuraloperator 2.0.0, MIT) cs→cs
с `n_modes` мод по оси (комплексные веса, rFFT, fft_norm="forward"), свёртка 1×1 cs→cout. Непериодичность: перед FFT
область дополняется ЧЁТНЫМ отражением (x[-1-i]) на половину стороны с каждого края (N → 2N, как линейная база P3), после —
обрезается; чётное продолжение непрерывно на стыке, поэтому БПФ на 2N нет «скачка» периодического замыкания, а область
физической задачи (край — «повтор», как Conv3) остаётся центральной. FFT — в fp32 вне autocast (cuFFT не умеет bf16, а 96,
192 — не степени двойки).

ONNX: torch.fft / комплексные веса в opset 17 не экспортируются. `for_export()` заменяет каждый SpectralConv
эквивалентным `SpecDFT` — те же веса, прямое и обратное преобразования — умножения на усечённые матрицы ДПФ (только
сохранённые моды), комплексная арифметика — парами вещественных; результат совпадает с библиотечным слоем до ~1e-6
(`tests/test_fno.py`).
"""
from __future__ import annotations

import math

import torch
from torch import nn

from .model import Conv3, FiLMBlock, gn


def mirror_pad(x, p):
    """Чётное отражение (край повторяется: x[-1-i]) на p с каждой стороны по двум последним осям; flip+срез+cat (детерминированный
    обратный ход, ONNX: Slice/Concat)."""
    x = torch.cat([x[:, :, :p].flip(2), x, x[:, :, -p:].flip(2)], dim=2)
    return torch.cat([x[:, :, :, :p].flip(3), x, x[:, :, :, -p:].flip(3)], dim=3)


class SpecDFT(nn.Module):
    """Экспортируемый двойник библиотечного SpectralConv (2D, rFFT, fft_norm="forward", без смещения, без факторизации):
    y = irfft2( W ⊙ fftshift-срез(rfft2(x)) ). Веса (cin, cout, m1, m2h) комплексные — хранятся парой вещественных."""

    def __init__(self, w, H, W):
        super().__init__()
        cin, cout, m1, m2h = w.shape
        self.m1, self.m2h = m1, m2h
        wr = torch.view_as_real(w.detach().cpu().to(torch.complex64))          # (cin, cout, m1, m2h, 2)
        wr = wr.permute(2, 3, 0, 1, 4).reshape(m1 * m2h, cin, cout, 2)
        self.register_buffer("wr", wr[..., 0].contiguous())
        self.register_buffer("wi", wr[..., 1].contiguous())
        k1 = torch.arange(m1, dtype=torch.float64) - m1 // 2                       # частоты по оси 0 (после fftshift)
        k2 = torch.arange(m2h, dtype=torch.float64)
        h = torch.arange(H, dtype=torch.float64)
        wv = torch.arange(W, dtype=torch.float64)
        a = 2 * math.pi * k1[:, None] * h[None, :] / H                             # (m1, H)
        b = 2 * math.pi * k2[:, None] * wv[None, :] / W                            # (m2h, W)
        c2 = torch.where(k2 == 0, 1.0, 2.0)[:, None]                               # вес Эрмитовой половины
        f = lambda t: t.float().contiguous()  # noqa: E731
        self.register_buffer("Ahr", f(torch.cos(a) / H)); self.register_buffer("Ahi", f(-torch.sin(a) / H))   # прямое, 1/N
        self.register_buffer("Awr", f((torch.cos(b) / W).t())); self.register_buffer("Awi", f((-torch.sin(b) / W).t()))
        self.register_buffer("Bhr", f(torch.cos(a).t())); self.register_buffer("Bhi", f(torch.sin(a).t()))    # обратное
        self.register_buffer("Cw", f(c2 * torch.cos(b))); self.register_buffer("Sw", f(c2 * torch.sin(b)))

    def forward(self, x):
        B, C = x.shape[:2]
        tr, ti = x @ self.Awr, x @ self.Awi                                        # (B, C, H, m2h)
        xr = self.Ahr @ tr - self.Ahi @ ti                                         # (B, C, m1, m2h)
        xi = self.Ahr @ ti + self.Ahi @ tr
        M = self.m1 * self.m2h
        xr = xr.reshape(B, C, M).permute(2, 0, 1)                                  # (M, B, C)
        xi = xi.reshape(B, C, M).permute(2, 0, 1)
        orr = xr @ self.wr - xi @ self.wi                                          # (M, B, cout)
        oi = xr @ self.wi + xi @ self.wr
        cout = orr.shape[-1]
        orr = orr.permute(1, 2, 0).reshape(B, cout, self.m1, self.m2h)
        oi = oi.permute(1, 2, 0).reshape(B, cout, self.m1, self.m2h)
        ur = self.Bhr @ orr - self.Bhi @ oi                                        # (B, cout, H, m2h)
        ui = self.Bhr @ oi + self.Bhi @ orr
        return ur @ self.Cw - ui @ self.Sw                                         # (B, cout, H, W)


class SpecBranch(nn.Module):
    """1×1 вниз → отражение ×2 → спектральный слой → обрезка → 1×1 вверх. size — сторона области уровня."""

    def __init__(self, cin, cout, cs, modes, size):
        super().__init__()
        from neuralop.layers.spectral_convolution import SpectralConv
        self.size, self.pad = size, size // 2
        self.down = nn.Conv2d(cin, cs, 1)
        self.sp = SpectralConv(cs, cs, n_modes=(modes, modes), bias=False, fft_norm="forward")
        self.up = nn.Conv2d(cs, cout, 1)
        self.dft = None

    def forward(self, x):
        z = self.down(x)
        with torch.autocast(device_type=z.device.type, enabled=False):
            z = mirror_pad(z.float(), self.pad)
            z = self.dft(z) if self.dft is not None else self.sp(z)
            z = z[:, :, self.pad:self.pad + self.size, self.pad:self.pad + self.size]
        return self.up(z)

    def to_dft(self):
        n = self.size + 2 * self.pad
        self.dft = SpecDFT(self.sp.weight.tensor, n, n)
        return self


class FNOBlock(FiLMBlock):
    """FiLMBlock с параллельной спектральной веткой на входе первой свёртки: n1(conv3×3(x) + спектр(x))."""

    def __init__(self, cin, cout, emb, cs=0, modes=0, size=0):
        super().__init__(cin, cout, emb)
        self.spec = SpecBranch(cin, cout, cs, modes, size) if modes else None

    def forward(self, x, e):
        g, b = self.film(e).chunk(2, dim=1)
        a = self.c1(x)
        if self.spec is not None:
            a = a + self.spec(x).to(a.dtype)
        h = self.n1(a)
        h = h * (1 + g[:, :, None, None]) + b[:, :, None, None]
        h = self.act(h)
        h = self.act(self.n2(self.c2(h)))
        return h + self.skip(x)


class UFNO(nn.Module):
    """Как UNetFiLM (4 спуска, 5 уровней 96→6), но блоки уровней со спектральной веткой: modes[i] — мод по оси на уровне
    i (0 — без ветки), cs — ширина спектральной части. Декодер — зеркально."""

    def __init__(self, n_maps=9, n_film=18, n_out=91, ch=(24, 48, 72, 96, 144), emb=128, cs=24,
                 modes=(24, 20, 16, 0, 0), size=96):
        super().__init__()
        self.emb = nn.Sequential(nn.Linear(n_film, emb), nn.SiLU(), nn.Linear(emb, emb), nn.SiLU())
        self.inp = Conv3(n_maps, ch[0])
        L = len(ch)
        sz = [size // 2 ** i for i in range(L)]
        self.enc, self.down = nn.ModuleList(), nn.ModuleList()
        c = ch[0]
        for i, co in enumerate(ch):
            self.enc.append(FNOBlock(c, co, emb, cs, modes[i], sz[i]))
            c = co
            if i < L - 1:
                self.down.append(nn.Conv2d(co, co, 2, stride=2))
        self.mid = FNOBlock(c, c, emb, cs, modes[L - 1], sz[L - 1])
        self.up, self.dec = nn.ModuleList(), nn.ModuleList()
        for i in range(L - 2, -1, -1):
            self.up.append(nn.ConvTranspose2d(c, ch[i], 2, stride=2))
            self.dec.append(FNOBlock(2 * ch[i], ch[i], emb, cs, modes[i], sz[i]))
            c = ch[i]
        self.out = nn.Conv2d(c, n_out, 1)
        self.register_buffer("out_scale", torch.ones(n_out))

    def forward(self, maps, nums):
        e = self.emb(nums)
        x = self.inp(maps)
        skips = []
        for i, blk in enumerate(self.enc):
            x = blk(x, e)
            if i < len(self.down):
                skips.append(x)
                x = self.down[i](x)
        x = self.mid(x, e)
        for up, blk in zip(self.up, self.dec):
            x = up(x)
            x = blk(torch.cat([x, skips.pop()], dim=1), e)
        return self.out(x) * self.out_scale[None, :, None, None]

    def for_export(self):
        """Копия без torch.fft: спектральные слои → матрицы ДПФ (SpecDFT)."""
        import copy
        m = copy.deepcopy(self).cpu().float().eval()
        for mod in m.modules():
            if isinstance(mod, SpecBranch):
                mod.to_dft()
        return m
