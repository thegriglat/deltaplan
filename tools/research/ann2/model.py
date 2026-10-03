"""AN-2: сеть «2,5D-оператор» (план ann2 §3, контракт A2 v1).

  карты 2D (N_MAPS) ─► ConvNeXt энкодер-декодер (FiLM от вектора условий) ─ узкое место 1/8: внимание по грубым
  токенам (≤ 12×12, любой размер карты) ─► карта признаков F(x,y) (64 канала)
  профиль U(z), θ̄(z) (13 уровней П1) + скаляры ─► 1D энкодер ─► вектор условий c (FiLM каждого блока, смещение головы)
  голова колонки: MLP(F(x,y), Fourier(η), U(η), θ̄(η), c) → du_par, du_perp, w, θ′, log σ × 4.
Полностью свёрточная: карта 64², 96² и любая кратная 8 (иначе — реплицирующее дополнение до кратного 8 и обрезка).
Нет абсолютных координат; граница карты видна только через нулевое дополнение свёрток (README).

`python model.py --count` печатает `params_M <число>`.
"""
from __future__ import annotations

import argparse
import math

import torch
import torch.nn as nn
import torch.nn.functional as Fn

import phys

COND = 128
FEAT = 64
TOK_MAX = 12


class Block(nn.Module):
    """ConvNeXt-блок (dw 7×7, LN, FiLM, MLP ×r) с масштабом слоя."""

    def __init__(self, c, cd=COND, ratio=4, film=True):
        super().__init__()
        self.dw = nn.Conv2d(c, c, 7, padding=3, groups=c)
        self.ln = nn.LayerNorm(c)
        self.film = nn.Linear(cd, 2 * c) if film else None
        if film:
            nn.init.zeros_(self.film.weight)
            nn.init.zeros_(self.film.bias)
        self.pw1 = nn.Linear(c, ratio * c)
        self.pw2 = nn.Linear(ratio * c, c)
        self.gamma = nn.Parameter(torch.full((c,), 0.1))

    def forward(self, x, cond):
        y = self.ln(self.dw(x).permute(0, 2, 3, 1))
        if self.film is not None:
            g, b = self.film(cond).chunk(2, -1)
            y = y * (1 + g[:, None, None]) + b[:, None, None]
        y = self.pw2(Fn.gelu(self.pw1(y))) * self.gamma
        return x + y.permute(0, 3, 1, 2)


class Stage(nn.Module):
    def __init__(self, c, depth, ratio=4):
        super().__init__()
        self.blocks = nn.ModuleList(Block(c, ratio=ratio) for _ in range(depth))

    def forward(self, x, cond):
        for b in self.blocks:
            x = b(x, cond)
        return x


class Down(nn.Module):
    def __init__(self, ci, co):
        super().__init__()
        self.ln = nn.GroupNorm(1, ci)
        self.conv = nn.Conv2d(ci, co, 2, stride=2)

    def forward(self, x):
        return self.conv(self.ln(x))


class Up(nn.Module):
    """Повышение разрешения ×2 (ближайший сосед + 1×1) и слияние с пропуском: concat → 1×1."""

    def __init__(self, ci, cs, co):
        super().__init__()
        self.up = nn.Conv2d(ci, co, 1)
        self.fuse = nn.Conv2d(2 * co if cs else co, co, 1)
        self.cs = cs
        if cs:
            self.skip = nn.Conv2d(cs, co, 1)

    def forward(self, x, skip):
        x = self.up(Fn.interpolate(x, scale_factor=2, mode="nearest"))
        if self.cs:
            x = torch.cat([x, self.skip(skip)], 1)
        return self.fuse(x)


class AttnLayer(nn.Module):
    def __init__(self, d, heads=6, cd=COND):
        super().__init__()
        self.cpe = nn.Conv2d(d, d, 3, padding=1, groups=d)        # условное позиционное кодирование (сетка токенов)
        self.ln1, self.ln2 = nn.LayerNorm(d), nn.LayerNorm(d)
        self.attn = nn.MultiheadAttention(d, heads, batch_first=True)
        self.mlp = nn.Sequential(nn.Linear(d, 2 * d), nn.GELU(), nn.Linear(2 * d, d))
        self.film = nn.Linear(cd, 2 * d)
        nn.init.zeros_(self.film.weight)
        nn.init.zeros_(self.film.bias)

    def forward(self, x, cond):                                   # x (B, d, h, w)
        B, d, h, w = x.shape
        x = x + self.cpe(x)
        t = x.flatten(2).transpose(1, 2)
        g, b = self.film(cond).chunk(2, -1)
        y = self.ln1(t) * (1 + g[:, None]) + b[:, None]
        t = t + self.attn(y, y, y, need_weights=False)[0]
        t = t + self.mlp(self.ln2(t))
        return t.transpose(1, 2).reshape(B, d, h, w)


class CoarseAttention(nn.Module):
    """Внимание по грубым токенам: карта 1/8 > 12×12 усредняется до 12×12, поправка возвращается билинейно."""

    def __init__(self, d, layers=2):
        super().__init__()
        self.layers = nn.ModuleList(AttnLayer(d) for _ in range(layers))

    def forward(self, x, cond):
        h, w = x.shape[-2:]
        th, tw = min(h, TOK_MAX), min(w, TOK_MAX)
        z = Fn.adaptive_avg_pool2d(x, (th, tw)) if (th, tw) != (h, w) else x
        y = z
        for l in self.layers:
            y = l(y, cond)
        d = y - z
        if (th, tw) != (h, w):
            d = Fn.interpolate(d, size=(h, w), mode="bilinear", align_corners=False)
        return x + d


class ProfileEncoder(nn.Module):
    """1D энкодер профиля (U, θ̄, log η на 13 уровнях) + скаляры → вектор условий (COND)."""

    def __init__(self, n_scal=phys.N_SCAL, cd=COND):
        super().__init__()
        self.conv = nn.Sequential(nn.Conv1d(phys.N_PROF_CH, 32, 3, padding=1), nn.GELU(),
                                  nn.Conv1d(32, 48, 3, padding=1), nn.GELU())
        self.mlp = nn.Sequential(nn.Linear(48 * 13 + n_scal, 2 * cd), nn.GELU(), nn.Linear(2 * cd, cd), nn.GELU(),
                                 nn.Linear(cd, cd))

    def forward(self, prof, scal):
        return self.mlp(torch.cat([self.conv(prof).flatten(1), scal], 1))


def point_feats(par, eta, nf=6):
    """Признаки точки (колонка, η): [u, sin/cos(2^k π u)·(k<nf), U(η)/10, θ̄(η)/5, η/1000]; par (B,4), eta (B,K,h,w) → (B,K,h,w,·)."""
    a, mp, U10, hm = (par[:, i].view(-1, 1, 1, 1) for i in range(4))
    u = phys.log_eta(eta)
    U = phys.u_profile(eta, a, mp, U10)
    th = phys.theta_bg(eta, hm)
    fr = [u]
    for k in range(nf):
        fr += [torch.sin(math.pi * 2 ** k * u), torch.cos(math.pi * 2 ** k * u)]
    fr += [U / 10.0, th / 5.0, eta / 1000.0]
    return torch.stack(fr, -1)


N_PF = 1 + 12 + 3


class Head(nn.Module):
    """MLP колонки: первый слой — сумма вкладов (карта признаков, условия, признаки точки)."""

    def __init__(self, feat=FEAT, d=128, cd=COND, n_out=8):
        super().__init__()
        self.a = nn.Conv2d(feat, d, 1)
        self.c = nn.Linear(cd, d)
        self.p = nn.Linear(N_PF, d)
        self.m1 = nn.Linear(d, d)
        self.m2 = nn.Linear(d, d)
        self.out = nn.Linear(d, n_out)

    def forward(self, Fm, cond, pf):
        # Fm (B,feat,H,W), pf (B,K,H,W,N_PF)
        a = self.a(Fm).permute(0, 2, 3, 1)[:, None]                 # (B,1,H,W,d)
        h = Fn.gelu(a + self.c(cond)[:, None, None, None] + self.p(pf))
        h = h + Fn.gelu(self.m1(h))
        h = h + Fn.gelu(self.m2(h))
        return self.out(h)                                          # (B,K,H,W,8)


SIG_FLOOR = (0.005, 0.005, 0.005, 0.02)     # нижний предел σ: доли U, К (порядок шума решателя 0,01 м/с)


class Ann2(nn.Module):
    def __init__(self, ch=(32, 64, 128, 192), depth=(2, 2, 3, 2), dec_depth=(2, 2, 2), attn_layers=2, feat=FEAT,
                 head_d=128):
        super().__init__()
        c1, c2, c3, c4 = ch
        self.stem = nn.Conv2d(phys.N_MAPS, c1, 3, padding=1)
        self.prof = ProfileEncoder()
        self.e1, self.e2 = Stage(c1, depth[0], 2), Stage(c2, depth[1], 2)
        self.e3, self.e4 = Stage(c3, depth[2]), Stage(c4, depth[3])
        self.d1, self.d2, self.d3 = Down(c1, c2), Down(c2, c3), Down(c3, c4)
        self.att = CoarseAttention(c4, attn_layers)
        self.u3, self.u2, self.u1 = Up(c4, c3, c3), Up(c3, c2, c2), Up(c2, c1, feat)
        self.g3, self.g2, self.g1 = Stage(c3, dec_depth[0]), Stage(c2, dec_depth[1], 2), Stage(feat, dec_depth[2], 2)
        self.head = Head(feat, head_d)
        self.register_buffer("floor", torch.tensor(SIG_FLOOR))

    def condition(self, maps, scal, prof):
        """Вектор условий; Fr⁻¹ (scal[:, 20]) — из карты рельефа окна, U10 — из профиля (канал 0, первый уровень не нужен:
        U10 = scal[:, 0]·10)."""
        scal = scal.clone()
        scal[:, 20] = phys.fr_inv(maps[:, 0], scal[:, 0] * 10.0)
        return self.prof(prof, scal)

    def features(self, maps, scal, prof):
        """Карта признаков F(x,y) (B, feat, H, W) и вектор условий."""
        B, _, H, W = maps.shape
        ph, pw = (-H) % 8, (-W) % 8
        x = Fn.pad(maps, (0, pw, 0, ph), mode="replicate") if ph or pw else maps
        c = self.condition(maps, scal, prof)
        s1 = self.e1(self.stem(x), c)
        s2 = self.e2(self.d1(s1), c)
        s3 = self.e3(self.d2(s2), c)
        s4 = self.att(self.e4(self.d3(s3), c), c)
        y = self.g3(self.u3(s4, s3), c)
        y = self.g2(self.u2(y, s2), c)
        y = self.g1(self.u1(y, s1), c)
        return y[..., :H, :W], c

    def decode(self, Fm, c, par, eta):
        """Колонки на высотах eta (B,K,H,W) м → (B,K,8,H,W) float32: μ (4: du_par, du_perp, w, θ′) и log σ (4)."""
        pf = point_feats(par, eta)
        o = self.head(Fm, c, pf.to(Fm.dtype)).float()
        mu = o[..., :4]
        ls = 0.5 * torch.log(self.floor ** 2 + torch.exp(2 * o[..., 4:].clamp(max=6.0)))
        return torch.cat([mu, ls], -1).permute(0, 1, 4, 2, 3)

    def forward(self, maps, scal, prof, par, eta):
        Fm, c = self.features(maps, scal, prof)
        return self.decode(Fm, c, par, eta)


def count_params(m):
    return sum(p.numel() for p in m.parameters())


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", action="store_true")
    a = ap.parse_args()
    m = Ann2()
    n = count_params(m)
    print(f"params {n}")
    print(f"params_M {n / 1e6:.3f}")
