"""Случаи A1/A2, прогон swpy, классификатор SW4, строка таблицы."""
import json, math, os, shutil, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
from swpy import case as swcase, solver, io as swio   # noqa: E402
import theory as th                                   # noqa: E402

RAW = os.path.expanduser(os.environ.get("SWC8_RAW", "~/data/sw_charges/regimes"))
THR = {"bore_h": 0.02, "front_h": 0.01, "jump_h": 0.05, "jump_sharp": 2.0, "fr_lo": 0.85, "fr_hi": 1.15,
       "x_up_a": -10.0, "sponge_a": 5.0, "domain_a": 30.0, "dx_div": 20}


def mk_case(name, shape, M, a_h0, F0=None, h0=1000.0, b0=0.1, U0=None, cd=0.0, forcing="none", dxdiv=20,
            mapping=None, H=None, a=None, s=None):
    H = M * h0 if H is None else H
    a = a_h0 * h0 if a is None else a
    if s is None:
        s = H * math.sqrt(2) * math.exp(-0.5) / a if shape in ("ridge", "hill") else H / (2 * a)
    c = math.sqrt(b0 * h0)
    U0 = F0 * c if U0 is None else U0
    F0 = U0 / c
    dx = a / dxdiv
    nx = int(round(2 * THR["domain_a"] * dxdiv))
    sw = THR["sponge_a"] * a
    meta, arr = swcase.make_case(name, shape=shape, dim=1, H=H, s=s, nx=nx, dx=dx, h0=h0, b0=b0, U0=U0, cd=cd,
                                 forcing=forcing, sponge=(sw, 2 * a / c), steady_tol=5e-4, mapping=mapping)
    meta["source"]["a"] = a
    return meta, arr, dict(F0=F0, M=H / h0, a=a, c=c, U0=U0, h0=h0, b0=b0, H=H, s=s)


def t_end_for(F0, M, a, c, U0, tcap_mult=15):
    Tc = 2 * THR["domain_a"] * a / (U0 + c)
    cap = tcap_mult * Tc
    reg = th.regime_theory(F0, M)
    if reg in ("R3", "R5", "R6"):
        b = th.bore(F0, min(M, 0.95))
        if b is not None and b[1] > 0:
            s = b[1] * c
            return min(cap, 3 * a / c + 16 * a / s), "bore"
        return 3 * Tc, "R6"
    return 4 * Tc, "steady"


def add_jstart(meta, arr, F0, M, a, h0, U0, b0):
    x = (meta["grid"]["x0"] + (np.arange(meta["grid"]["nx"]) + 0.5) * meta["grid"]["dx"])
    zb = arr["zb"][0]
    h, xj, zj, clipped = th.jump_branch(zb / h0, x / a, F0, M)
    arr = dict(arr)
    arr["h_init"] = (h * h0)[None, :]
    arr["hu_init"] = np.full((1, len(x)), h0 * U0)
    arr["b_init"] = np.full((1, len(x)), b0)
    return arr, dict(x_j_theory=xj * a, z_j_theory=zj * h0, jump_clipped=clipped)


def _jump(h, x, h0, a, lo, hi, sharp=THR["jump_sharp"]):
    """Скачок h > 0,05 h0 на 2 клетках и резкий (охват 8 клеток ≤ 2× охвата 2 клеток); возвращает (bool, x)."""
    d2 = h[2:] - h[:-2]
    d8 = np.full_like(d2, np.inf)
    d8[3:-3] = h[8:] - h[:-8] if len(h) > 8 else d8[3:-3]
    xm = x[1:-1]
    ok = (xm > lo) & (xm < hi) & (d2 > THR["jump_h"] * h0) & (d8 <= sharp * d2 + 1e-12)
    if ok.any():
        i = np.where(ok)[0]
        k = i[np.argmax(d2[i])]
        return True, float(xm[k])
    return False, None


def analyse(meta, st, field, snaps, rec):
    g = meta["grid"]; nx = g["nx"]; dx = g["dx"]
    x = g["x0"] + (np.arange(nx) + 0.5) * dx
    a = meta["source"]["a"]; h0 = meta["ref"]["h0"]; b0 = meta["ref"]["b0"]
    h = field["h"][0]; hu = field["hu"][0]; hb = field["hb"][0]
    ic = nx // 2
    if meta["source"]["shape"] == "step_up":   # SW4 (уточнение): Fr_crest у step_up — в начале плато (zb >= 0,99 H)
        ip = int(np.argmax(field["zb"][0] >= 0.99 * meta["source"]["H"]))
        ic = ip + 1
    hc = 0.5 * (h[ic - 1] + h[ic]); huc = 0.5 * (hu[ic - 1] + hu[ic]); hbc = 0.5 * (hb[ic - 1] + hb[ic])
    fr_crest = abs(huc / hc) / math.sqrt(hbc / hc * hc) if hc > 1e-9 and hbc > 0 else None
    q_ratio = huc / (h0 * meta["ref"]["U0"]) if meta["ref"]["U0"] else None
    ju = int(np.argmin(abs(x - THR["x_up_a"] * a)))
    h_up = float(h[ju] / h0)
    # старт: сухие клетки
    zb = field["zb"][0]
    dry0 = int((np.maximum(0, h0 - zb) < meta["physics"]["h_min"]).sum())
    # бор: повышение в зонде в итоге + скорость фронта по снимкам
    bore = (h_up - 1) > THR["bore_h"]
    speed = None
    if bore:
        thr = max(THR["front_h"], 0.5 * (h_up - 1))
        pts = []
        for t, hs in snaps:
            m = (x >= -(THR["domain_a"] - THR["sponge_a"] - 0.5) * a) & (x <= -2 * a) & (hs / h0 - 1 >= thr)
            if m.any():
                pts.append((t, float(x[np.where(m)[0][0]])))
        pts = [p for p in pts if -(THR["domain_a"] - THR["sponge_a"] - 0.5) * a < p[1] <= -3 * a]
        if len(pts) >= 3:
            t_ = np.array([p[0] for p in pts]); x_ = np.array([p[1] for p in pts])
            slope = np.polyfit(t_, x_, 1)[0]
            speed = -float(slope)
        if speed is None or speed <= 0:
            for t, hs in snaps:
                if hs[ju] / h0 - 1 >= thr:
                    speed = 9 * a / t; break
        bore = bore and speed is not None and speed > 0
    stand, xs = _jump(h, x, h0, a, -3 * a, 0.0)
    lee, xl = _jump(h, x, h0, a, 0.0, (THR["domain_a"] - THR["sponge_a"]) * a)
    inr = fr_crest is not None and THR["fr_lo"] <= fr_crest <= THR["fr_hi"]
    F0 = meta["ref"]["U0"] / math.sqrt(b0 * h0)
    if dry0 > 0:
        reg = "R6"
    elif F0 < 1:
        reg = "R3" if (bore and inr) else "R1" if (not bore and fr_crest is not None and fr_crest < THR["fr_lo"]) else "unclassified"
    else:
        if bore and inr: reg = "R5"
        elif (not bore) and stand: reg = "R4j"
        elif (not bore) and (not stand) and fr_crest is not None and fr_crest > THR["fr_hi"]: reg = "R2"
        else: reg = "unclassified"
    return dict(regime_sw=reg, Fr_crest=fr_crest, h_up=h_up, bore_speed=speed if bore else None,
                lee_jump=bool(lee), x_jump=xl, q_ratio=q_ratio, dry_cells=rec["dry_cells"],
                stand_jump=bool(stand), x_stand=xs, dry_start=dry0)


def run_one(name, meta, arr, par, series, extra=None, rule_b0=None, Fr_game=None, N=None, z_i=None, tag=""):
    F0, M, a, c, U0 = par["F0"], par["M"], par["a"], par["c"], par["U0"]
    te, how = t_end_for(F0, M, a, c, U0)
    meta["run"]["t_end"] = te
    meta["run"]["out_every"] = max(2.0, te / 60)
    out = os.path.join(RAW, series, name)
    shutil.rmtree(out, ignore_errors=True); os.makedirs(out)
    swcase.write_case(out, meta, arr)
    t0 = time.time()
    field, rec = solver.run((meta, arr), out)
    wall = time.time() - t0
    snaps = []
    for f in sorted(os.listdir(out)):
        if ".t" in f and f.endswith(".field.json"):
            m, ar = swio.read_pair(os.path.join(out, f))
            snaps.append((m["t"], ar["h"][0]))
    snaps.sort(key=lambda p: p[0])
    an = analyse(meta, None, field, snaps, rec)
    for f in os.listdir(out):
        if ".t" in f and (f.endswith(".field.json") or f.endswith(".field.bin")):
            os.remove(os.path.join(out, f))
    reg_th = th.regime_theory(F0, M)
    row = dict(case=name, run=os.path.join(out, name + ".run.json"), shape=meta["source"]["shape"], s=par["s"], H=par["H"],
               h0=par["h0"], b0=par["b0"], U0=U0, F0=F0, M=M, Fr_game=Fr_game, N=N, z_i=z_i, rule_b0=rule_b0,
               regime_theory=reg_th, match=an["regime_sw"] in reg_th.split("|"), status=rec["status"], wall_s=wall)
    row.update({k: an[k] for k in ("regime_sw", "Fr_crest", "h_up", "bore_speed", "lee_jump", "x_jump", "q_ratio", "dry_cells")})
    # диагностика вне SW4 (в JSON под diag, в csv нет)
    b = th.bore(F0, M) if M < 1 else None
    row["diag"] = dict(a=a, a_h0=a / par["h0"], t_end=te, t_end_how=how, t_sim=rec["t"], steps=rec["steps"],
                       stand_jump=an["stand_jump"], x_stand=an["x_stand"], h1_theory=b[0] if b else None,
                       s_theory=b[1] * c if b else None, Mc=th.Mc(F0) if F0 < 3.5 else None,
                       mass_rel_err=rec["mass_rel_err"], steady_residual=rec["steady_residual"],
                       dxdiv=int(round(a / meta["grid"]["dx"])), **(extra or {}))
    return row
