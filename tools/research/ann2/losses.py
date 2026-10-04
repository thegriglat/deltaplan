"""AN-2: потеря — NLL Гаусса по каналам с масками + малый штраф дивергенции массового потока (контракт A2)."""
from __future__ import annotations

import torch

import phys
from model import SIG_FLOOR

H_RHO = 8500.0       # м, масштаб высоты плотности (экспонента ρ ∝ exp(−z/H))
DX = 400.0           # м, шаг сетки данных
CH_W = (1.0, 1.0, 1.0, 0.5)    # веса каналов NLL: du_par, du_perp, w, θ′


def nll(out, y, mask):
    """out (B,K,8,h,w): μ(4), log σ(4); y (B,K,4,h,w); mask (B,4) — маска канала по образцу (θ′ у решения m).
    NLL Гаусса: ½((y−μ)/σ)² + log σ, среднее по маске. → (скаляр, по каналам (4,))."""
    mu, ls = out[:, :, :4], out[:, :, 4:]
    # + const: log σ − log σ_floor ≥ 0 (потеря неотрицательна, отношение потерь осмысленно; градиент тот же)
    fl = torch.tensor(SIG_FLOOR, device=out.device).view(1, 1, 4, 1, 1)
    e = 0.5 * ((y - mu) * torch.exp(-ls)) ** 2 + (ls - torch.log(fl))
    m = mask[:, None, :, None, None]
    per = (e * m).sum((0, 1, 3, 4)) / (m.expand_as(e).sum((0, 1, 3, 4)).clamp(min=1.0))
    w = torch.tensor(CH_W, device=out.device)
    return (per * w).sum() / w.sum(), per


def divergence_penalty(out_div, eta_div, par, dx=DX):
    """Дивергенция массового потока отклонения от притока (анельастика ρ ∝ exp(−z/H), ось η — вдоль рельефа, члены
    наклона опущены): D = ∂x′u + ∂y′v + ∂ηw − w/H, по паре высот (η, 1,15·η) с одним η на всю вырезку; горизонтальные —
    центральные разности, вертикальная — разность пары. Нормировка: D·dx / max(U(η), 1) → квадрат, среднее по
    внутренним клеткам. out_div (B,2Kd,8,h,w) — порядок [η_1…η_Kd, 1,15η_1…]; eta_div (B,Kd,2)."""
    B, K2 = out_div.shape[:2]
    Kd = K2 // 2
    a, mp, U10 = (par[:, i].view(B, 1, 1, 1) for i in range(3))
    e1, e2 = eta_div[..., 0].view(B, Kd, 1, 1), eta_div[..., 1].view(B, Kd, 1, 1)
    s1 = phys.u_profile(e1, a, mp, U10).clamp(min=phys.U_FLOOR)
    s2 = phys.u_profile(e2, a, mp, U10).clamp(min=phys.U_FLOOR)
    f1, f2 = out_div[:, :Kd], out_div[:, Kd:]
    u1, v1, w1 = (f1[:, :, i] * s1 for i in range(3))
    u2, v2, w2 = (f2[:, :, i] * s2 for i in range(3))
    um, vm, wm = 0.5 * (u1 + u2), 0.5 * (v1 + v2), 0.5 * (w1 + w2)
    dudx = (um[..., 1:-1, 2:] - um[..., 1:-1, :-2]) / (2 * dx)
    dvdy = (vm[..., 2:, 1:-1] - vm[..., :-2, 1:-1]) / (2 * dx)
    dwdz = ((w2 - w1) / (e2 - e1))[..., 1:-1, 1:-1]
    D = dudx + dvdy + dwdz - wm[..., 1:-1, 1:-1] / H_RHO
    sc = (0.5 * (s1 + s2))[..., :1, :1]
    return ((D * dx / sc) ** 2).mean()
