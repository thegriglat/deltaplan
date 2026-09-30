"""Эталонные поля и промежуточные результаты блоков одной итерации Пикара для тестов GPU (AM-02/AM-03).

Счёт — float64 (air.py, CuPy), хранение — float32 little-endian, формат как у AM-02
(`gpu_block_refs.py`): `<случай>.bin` — массивы подряд, `<случай>.json` — размеры, смещения
(`arrays: {имя: [смещение, длина]}` в числах float32), параметры, критерий, итог решения.

Раскладка массива: (NZ, NY, NX) с ореолом, индекс (k·NY + j)·NX + i, dims = [NX, NY, NZ].
Шаблоны: C (7, NZ, NY, NX) — 0 центр, 1 −x, 2 +x, 3 −y, 4 +y, 5 −z, 6 +z.
Порядок блоков — reference.md → «Итерация Пикара». Все промежуточные массивы — от одного
входного состояния `in_*` (снимок после 20 итераций от фона, чтобы все члены были ненулевые);
вход блока — выход предыдущего (для проверки блока по отдельности берите его вход из файла).

    ../heat_ca/.venv/bin/python fixtures.py            # все случаи → tests/atmosphere/fixtures/air_model/ref/
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

import numpy as np

import air as A
import synth as SY

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "tests/atmosphere/fixtures/air_model/ref"
F64 = np.float64


def cases():
    """Маленькие сетки (32–48 клеток по горизонтали, 16–24 уровня)."""
    out = {}
    # 1. ровно с ветром (профиль, трение, устойчивость N = 0,01)
    g = A.Grid(200.0, 24, 24, 50.0, -50.0, 12, -2400.0, -2400.0)
    out["flat_wind"] = (g, np.full((24, 24), 5.0), A.Case(U10=5.0, wdir=250.0, gam=SY.const_gam(SY.GAM_N)), A.Params(dtau_u=600.0))
    # 2. хребет Аньези H = 300 м, L = 400 м, ветер поперёк (с запада), нейтрально
    g = A.Grid(100.0, 32, 24, 50.0, -50.0, 16, -1600.0, -1200.0)
    X, Y = np.meshgrid(g.x, g.y)
    hc = SY.ridge3d(X, Y, 300.0, 300.0, 600.0)
    out["agnesi"] = (g, hc, A.Case(U10=5.0, wdir=270.0, gam=SY.const_gam(0.0)), A.Params(dtau_u=600.0))
    # 3. прогретый склон без ветра: хребет, солнце на восточный склон, слой перемешивания до 1500 м
    g = A.Grid(100.0, 24, 24, 100.0, -100.0, 16, -1200.0, -1200.0)
    X, Y = np.meshgrid(g.x, g.y)
    hc = SY.ridge3d(X, Y, 400.0, 400.0, 600.0)
    H = SY.sun_flux(hc, g.dx, az=100.0, el=45.0)
    gam = SY.cbl_gam(1500.0, 5.8e-3)
    # pr_t явно ≠ 1 (не по умолчанию): шаблон тепла чувствителен к 1/Pr_t при любом значении по умолчанию
    out["heated_slope"] = (g, hc, A.Case(U10=0.0, gam=gam, z_i=1500.0, H=H), A.Params(dtau_u=600.0, pr_t=0.85))
    # 4. седловина: хребет 500 м с седловиной 250 м, ветер под 15° к оси, N = 0,01
    g = A.Grid(150.0, 24, 24, 100.0, -100.0, 16, -1800.0, -1800.0)
    X, Y = np.meshgrid(g.x, g.y)
    hc = SY.saddle3d(X, Y, L=400.0, s=300.0, half_len=900.0)
    out["saddle"] = (g, hc, A.Case(U10=5.0, wdir=255.0, gam=SY.const_gam(SY.GAM_N)), A.Params(dtau_u=600.0))
    return out


class Pack:
    def __init__(self):
        self.parts = []
        self.arrays = {}
        self.off = 0

    def add(self, name, a):
        a = np.ascontiguousarray(np.asarray(a, np.float64)).astype("<f4").ravel()
        self.arrays[name] = [self.off, int(a.size)]
        self.parts.append(a)
        self.off += a.size

    def write(self, path, meta):
        np.concatenate(self.parts).tofile(str(path) + ".bin")
        meta = dict(meta)
        meta["arrays"] = self.arrays
        Path(str(path) + ".json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))


def f32(a):
    return np.asarray(a, np.float64).astype(np.float32).astype(np.float64)


def G(a):
    return a.get() if hasattr(a, "get") else np.asarray(a)


def set_state(S, st):
    cp = S.cp
    for k in ("u", "v", "w", "th", "p"):
        getattr(S, k)[...] = cp.asarray(f32(st[k]), np.float64)


def make_case(name, g, hc, case, prm):
    S = A.Air(g, hc, case, prm, dtype=F64, taper=False)
    S.init_background()
    S.launch(20)                       # без графа (float64, мелко)
    st0 = {k: G(getattr(S, k)).copy() for k in ("u", "v", "w", "th", "p")}
    nu0 = G(S.nuf).copy()
    nuh0 = G(S.nuh).copy()
    P = Pack()
    # ---- постоянные входы
    P.add("hc", hc)
    P.add("cell", S.cell_np); P.add("tu", S.tu_np); P.add("tv", S.tv_np); P.add("tw", S.tw_np)
    P.add("nu_bg", S.nu_np); P.add("Q", S.Q_np); P.add("gam", S.gam_np)
    P.add("cplz", S.cplz_np); P.add("sp_u", S.sp_np); P.add("sp_w", S.spw_np); P.add("spc", S.spc_np)
    P.add("ubg", S.ubg_np); P.add("vbg", S.vbg_np); P.add("lam", S.lam_np)
    P.add("Kx", S.Kx_np); P.add("Ky", S.Ky_np); P.add("Kz", S.Kz_np)
    P.add("fixed_u", G(S.fixed_u)); P.add("fixed_v", G(S.fixed_v))
    P.add("b_u", G(S.b_u)); P.add("b_v", G(S.b_v))           # индексы граничных граней (целые, точно в f32 до 2^24)
    # ---- вход итерации
    for k, a in st0.items():
        P.add("in_" + k, a)
    set_state(S, st0)
    S.nuf[...] = S.cp.asarray(f32(nu0))
    S.nuh[...] = S.cp.asarray(f32(nuh0))
    # 1. граничные условия
    S.apply_bc()
    P.add("bc_u", G(S.u)); P.add("bc_v", G(S.v))
    # 1б. местное K (длина перемешивания), от состояния после граничных условий
    P.add("nu_in", G(S.nuf)); P.add("nuh_in", G(S.nuh))
    S.update_k()
    P.add("kloc_nu", G(S.nuf)); P.add("kloc_nuh", G(S.nuh))
    # 2. поправка переноса импульса (в эталоне выключена — нули; ядро и массив оставлены для полноты)
    S.adv2_mom()
    # 3. шаблоны импульса
    S.build_mom()
    for n, C, b in (("u", S.Cu, S.bu), ("v", S.Cv, S.bv), ("w", S.Cw, S.bw)):
        P.add("Cm_" + n, G(C)); P.add("bm_" + n, G(b))
    # 4. прогонки импульса: одна прогонка (z, x, y по u) и весь шаг
    u_save = S.u.copy()
    S.lines.sweep(S.Cu, S.u, S.bu)
    P.add("sweep1_u", G(S.u))
    S.u[...] = u_save
    S.mom_step()
    P.add("mom_u", G(S.u)); P.add("mom_v", G(S.v)); P.add("mom_w", G(S.w))
    # 5. проекция: правая часть, φ после одного V-цикла, скорости и p после
    cp = S.cp
    f = S.fluid[1:-1, 1:-1, 1:-1]
    rhs = S.divergence()
    P.add("div_star", G(rhs))
    rhs = rhs - cp.sum(rhs) / S.n_fluid * f
    P.add("proj_rhs", G(rhs))
    phi = cp.zeros_like(rhs)
    phi = S.mg.vcycle(0, phi, rhs)
    P.add("vcycle_phi_raw", G(phi))
    S.phi[...] = 0
    Pp = S.project(cycles=1)
    P.add("proj_phi", G(Pp))
    P.add("proj_u", G(S.u)); P.add("proj_v", G(S.v)); P.add("proj_w", G(S.w)); P.add("proj_p", G(S.p))
    P.add("div_after", G(S.divergence()))
    # 6. тепло
    S.adv2_heat()
    S.build_heat()
    P.add("Ch", G(S.Ct)); P.add("bh", G(S.bt))
    S.heat_step()
    P.add("heat_th", G(S.th))
    iter1 = {k: G(getattr(S, k)).copy() for k in ("u", "v", "w", "th", "p")}
    # ---- решение до конца (float64)
    S2 = A.Air(g, hc, case, prm, dtype=F64, taper=False)
    S2.init_background()
    status = S2.solve(max_outer=4000, graph=False)
    res_final = S2.hist[-1]
    S2.finalize()
    for k in ("u", "v", "w", "th", "p"):
        P.add("sol_" + k, G(getattr(S2, k)))
    u, v, w, th = S2.centers()
    NZ, NY, NX = S.shape
    levels = [list(L["shape"])[::-1] for L in S.mg.levels]
    meta = dict(case=name, dims=[NX, NY, NZ], halo=1, dx=g.dx, dz=g.dz, z_bot=g.z_bot, x0=g.x0, y0=g.y0,
                nx=g.nx, ny=g.ny, nz=g.nz,
                params={k: getattr(prm, k) for k in prm.__dataclass_fields__},
                case_params=dict(U10=case.U10, wdir=case.wdir, z_i=case.z_i, U_aloft=S.U_a, label=case.label),
                cd=S.cd, fixed_scale=S.fixed_scale, n_fluid=S.n_fluid, closure=S.closure_info,
                mg_levels_xyz=levels,
                criterion=dict(tol_mom_rms=2e-5, tol_th_rms=5e-7, tol_div_rms=1e-6, check_every=10),
                solution=dict(status=status, iters=S2.outer, final_residuals=res_final,
                              max_speed=float(np.nanmax(np.sqrt(u ** 2 + v ** 2 + w ** 2))),
                              w_range=[float(np.nanmin(w)), float(np.nanmax(w))],
                              th_range=[float(np.nanmin(th)), float(np.nanmax(th))]),
                history=[dict(it=h["it"], mom_rms=h["mom_rms"], th_rms=h["th_rms"], div_rms=h["div_rms"])
                         for h in S2.hist],
                notes="in_*, nu_in, nuh_in — вход итерации (nu_bg — фоновое K_b, не меняется); bc_* → kloc_nu/kloc_nuh → Cm_*/bm_* → sweep1_u (одна прогонка u: z, x, y; "
                      "зебра 0, 1) → mom_* (весь шаг импульса) → div_star → proj_rhs (минус среднее) → "
                      "vcycle_phi_raw (один V-цикл от нуля) → proj_phi (после вычитания среднего, с ореолом 0) → "
                      "proj_u/v/w/p → div_after → Ch/bh → heat_th. sol_* — решение до критерия + "
                      "finalize (10 V-циклов без изменения p). Целочисленные массивы (типы, индексы) — в float32.")
    OUT.mkdir(parents=True, exist_ok=True)
    P.write(OUT / name, meta)
    size = (OUT / (name + ".bin")).stat().st_size / 2 ** 20
    print(f"{name}: {NX}×{NY}×{NZ}, {status} за {S2.outer} итераций, {size:.2f} МБ", flush=True)
    return meta


if __name__ == "__main__":
    only = sys.argv[1:]
    for name, (g, hc, case, prm) in cases().items():
        if only and name not in only:
            continue
        make_case(name, g, hc, case, prm)
