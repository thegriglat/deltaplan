"""Малый U-Net + FiLM для области 96² (контракт П2): вход — карты (B, 4, 96, 96) и числа (B, 18), выход —
цель П2 (B, 91, 96, 96). Операторы — простые для ONNX (Conv, ConvTranspose, GroupNorm, SiLU, Gemm, Slice/Concat).

Сеть предсказывает цель, делённую на масштаб канала (std по обучению, `out_scale`), и умножает на масштаб
внутри себя — выход модели и ONNX сразу в единицах контракта П2.
"""
from __future__ import annotations

import torch
from torch import nn


class Conv3(nn.Module):
    """Свёртка 3×3 с краем «повтор» (как поле на границе области). Край — срезами и склейкой, а не
    ReplicationPad: у его обратного хода на CUDA нет детерминированной версии (use_deterministic_algorithms)."""

    def __init__(self, cin, cout):
        super().__init__()
        self.conv = nn.Conv2d(cin, cout, 3)

    def forward(self, x):
        x = torch.cat([x[:, :, :1], x, x[:, :, -1:]], dim=2)
        x = torch.cat([x[:, :, :, :1], x, x[:, :, :, -1:]], dim=3)
        return self.conv(x)


def gn(c):
    return nn.GroupNorm(min(8, c // 4) if c >= 8 else 1, c)


class FiLMBlock(nn.Module):
    """conv3×3 → GN → FiLM(γ, β) → SiLU → conv3×3 → GN → SiLU, + обход 1×1."""

    def __init__(self, cin, cout, emb):
        super().__init__()
        self.c1 = Conv3(cin, cout)
        self.n1 = gn(cout)
        self.c2 = Conv3(cout, cout)
        self.n2 = gn(cout)
        self.film = nn.Linear(emb, 2 * cout)
        nn.init.zeros_(self.film.weight)
        nn.init.zeros_(self.film.bias)
        self.skip = nn.Conv2d(cin, cout, 1) if cin != cout else nn.Identity()
        self.act = nn.SiLU()

    def forward(self, x, e):
        g, b = self.film(e).chunk(2, dim=1)
        h = self.n1(self.c1(x))
        h = h * (1 + g[:, :, None, None]) + b[:, :, None, None]
        h = self.act(h)
        h = self.act(self.n2(self.c2(h)))
        return h + self.skip(x)


class UNetFiLM(nn.Module):
    def __init__(self, n_maps=4, n_film=18, n_out=91, ch=(32, 64, 96, 128, 192), emb=128):
        super().__init__()
        self.emb = nn.Sequential(nn.Linear(n_film, emb), nn.SiLU(), nn.Linear(emb, emb), nn.SiLU())
        self.inp = Conv3(n_maps, ch[0])
        self.enc = nn.ModuleList()
        self.down = nn.ModuleList()
        c = ch[0]
        for i, co in enumerate(ch):
            self.enc.append(FiLMBlock(c, co, emb))
            c = co
            if i < len(ch) - 1:
                self.down.append(nn.Conv2d(co, co, 2, stride=2))
        self.mid = FiLMBlock(c, c, emb)
        self.up = nn.ModuleList()
        self.dec = nn.ModuleList()
        for co in reversed(ch[:-1]):
            self.up.append(nn.ConvTranspose2d(c, co, 2, stride=2))
            self.dec.append(FiLMBlock(2 * co, co, emb))
            c = co
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


def build(cfg_model, n_maps, n_film, n_out):
    if cfg_model.get("arch", "unet") == "ufno":                  # P3E7: U-FNO (pilotnn/fno.py)
        from .fno import UFNO
        return UFNO(n_maps, n_film, n_out, tuple(cfg_model["channels"]), cfg_model["emb"], cfg_model["spec_ch"],
                    tuple(cfg_model["modes"]))
    return UNetFiLM(n_maps, n_film, n_out, tuple(cfg_model["channels"]), cfg_model["emb"])


def n_params(m):
    return sum(p.numel() for p in m.parameters())
