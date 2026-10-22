#!/usr/bin/env python3
"""Установившийся набор буксировщика с дельтапланом sport на тросе (баланс сил/мощности) и проверка модели."""
import json, math, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tugmodel import *
import cart

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))

def glider_sink(sport, mass_total, V):
    ref = sport["pilot_mass_ref_kg"] + sport["wing_mass_kg"]
    s = math.sqrt(mass_total / ref)
    pts = sport["polar"]["points_kmh_ms"]
    xs = [p[0] * s / 3.6 for p in pts]; ys = [p[1] * s for p in pts]
    return interp(V, xs, ys)

def solve(prop, wing, m_tug, cda, V, m_glider=0.0, sport=None):
    """Возвращает (roc, T, D_tug, tension, gamma)."""
    T = prop.full(V)[1]
    gam = 0.0
    for _ in range(100):
        L = m_tug * G * math.cos(gam)
        _, Dw = wing.drag(V, L)
        Dt = Dw + 0.5 * RHO * V**2 * cda
        if m_glider > 0:
            Wg = m_glider * G
            Dg = Wg * glider_sink(sport, m_glider, V) / V
            ten = Dg + Wg * math.sin(gam)
        else:
            ten = 0.0; Dg = 0.0
        s = (T - Dt - Dg) / ((m_tug + m_glider) * G)
        gam_new = math.asin(max(-1, min(1, s)))
        if abs(gam_new - gam) < 1e-9: break
        gam = gam_new
    return V * math.sin(gam), T, Dt, ten, gam

def main():
    cda = cart.cda()
    wing = Wing(cda)
    tug = json.load(open(os.path.join(ROOT, "configs", "tow_tug.json")))
    sport = json.load(open(os.path.join(ROOT, "configs", "wings", "sport.json")))
    p582, p912 = Prop(R582), Prop(R912)
    m_tug = cart.EMPTY + cart.PILOT + cart.FUEL + 53.0   # тележка + пилот + топливо + iXess 15
    V = tug["tow_speed_kmh"] / 3.6
    mg = 100.0 + sport["wing_mass_kg"]
    roc, T, Dt, ten, gam = solve(p582, wing, m_tug, cda, V, mg, sport)
    print("climb_ms=%.2f speed_kmh=%.1f thrust_n=%.0f drag_n=%.0f tension_n=%.0f" % (roc, tug["tow_speed_kmh"], T, Dt, ten))
    out = {"main": dict(climb_ms=roc, speed_kmh=tug["tow_speed_kmh"], thrust_n=T, drag_n=Dt, tension_n=ten, gamma_deg=math.degrees(gam),
                        m_tug_kg=m_tug, m_glider_kg=mg, cda_m2=cda)}
    rows = []
    def row(name, prop, mt, mgl, vk):
        r = solve(prop, wing, mt, cda, vk / 3.6, mgl, sport if mgl else None)
        rows.append(dict(case=name, speed_kmh=vk, m_tug_kg=mt, m_glider_kg=mgl, climb_ms=round(r[0], 2), thrust_n=round(r[1]), drag_n=round(r[2]), tension_n=round(r[3])))
        print("  %-52s V=%5.1f  roc=%5.2f  T=%5.0f D=%4.0f tens=%4.0f" % (name, vk, r[0], r[1], r[2], r[3]))
    print("варианты (не подгонка, справка):")
    for vk in (55, 60, 65, 70, 75):
        row("582 + sport 100 кг на тросе", p582, m_tug, mg, vk)
    row("582 без дельтаплана", p582, m_tug, 0, 60)
    row("582 без дельтаплана, лучший набор", p582, m_tug, 0, 75)
    row("582 + sport 80 кг пилот", p582, m_tug, 80 + sport["wing_mass_kg"], 60)
    row("582 + sport 100 кг, пустой бак (15 кг)", p582, m_tug - 15, mg, 60)
    m912 = 197.0 + cart.PILOT + cart.FUEL + 53.0
    row("912ULS (тележка 197 кг) + sport 100 кг", p912, m912, mg, 60)
    row("912ULS без дельтаплана", p912, m912, 0, 60)
    # проверка модели: Tanarg/iXess 15, 912ULS, MTOW 450 кг, 83.3 км/ч (HADS HM16: 5.49 м/с)
    r = solve(p912, wing, 450.0, cda, 83.3 / 3.6)
    print("проверка по паспорту: 912ULS, 450 кг, 83.3 км/ч: roc=%.2f (HADS HM16 Annex F: 5.49)" % r[0])
    out["passport_check_912"] = dict(roc_model=r[0], roc_passport=5.49, rel_err=(r[0] - 5.49) / 5.49)
    # оптимальная скорость набора без дельтаплана
    best = max(((solve(p912, wing, 450.0, cda, v / 3.6)[0], v) for v in range(60, 120)))
    out["passport_check_912"]["best_roc_model"] = best
    out["variants"] = rows
    out["wing"] = dict(CD0=wing.CD0, k=wing.k, CLmax=wing.CLmax, best_ld_cl_ld=wing.best_ld())
    out["props"] = {e["name"]: dict(Ct0=Prop(e).Ct0, Cp0=Prop(e).Cp0, J0=Prop(e).J0, T_static=Prop(e).T_static_design) for e in (R582, R912)}
    json.dump(out, open(os.path.join(os.path.dirname(__file__), "climb_estimate.json"), "w"), ensure_ascii=False, indent=1)

if __name__ == "__main__":
    main()
