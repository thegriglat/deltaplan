"""Серия режимов: python run_series.py <часть> -> RAW/rows_<часть>.jsonl. Части: a1a..a1d, a2, chk."""
import json, sys, os
import core, theory as th
from core import *

A1_F = [0.2, 0.3, 0.5, 0.7, 0.85, 1.2, 1.5, 2, 3]
A1_M = [0.05, 0.1, 0.2, 0.3, 0.4, 0.6, 0.8, 1.0, 1.2]
CTL_F = [0.5, 1.5, 2]
SUPP = [(1.5, 0.13), (2, 0.5), (1.2, 0.024)]
SH = {"ridge": "r", "step_up": "su"}


def jobs_a1(part):
    J = []
    def add(shape, ah, F, M, dxdiv=20, supp=False):
        J.append((shape, ah, F, M, dxdiv, supp))
    for F in A1_F:
        for M in A1_M: add("ridge", 3, F, M)
    for F, M in SUPP: add("ridge", 3, F, M, supp=True)
    for F in CTL_F:
        for M in A1_M:
            add("ridge", 6, F, M); add("step_up", 3, F, M)
    for (F, M) in [(0.5, 0.3), (1.5, 0.3), (2, 0.4)]:
        add("ridge", 3, F, M, dxdiv=40)
    if part == "a1su":
        return [j for j in J if j[0] == "step_up"]
    n = {"a1a": 0, "a1b": 1, "a1c": 2, "a1d": 3}[part]
    return [j for i, j in enumerate(J) if i % 4 == n and j[0] != "step_up"]


def name_a1(shape, ah, F, M, dxdiv, js=False):
    n = f"A1_{SH[shape]}{ah}_F{F:.3f}_M{M:.3f}"
    if dxdiv != 20: n += f"_dx{dxdiv}"
    return n + ("_jstart" if js else "")


def do_a1(part, out):
    for shape, ah, F, M, dxdiv, supp in jobs_a1(part):
        meta, arr, par = mk_case(name_a1(shape, ah, F, M, dxdiv), shape, M, ah, F0=F, dxdiv=dxdiv)
        row = run_one(meta["name"], meta, arr, par, "A1", extra=dict(supp=supp))
        emit(out, row)
        th_r = row["regime_theory"]
        if F > 1 and th_r == "R2|R4j":
            ms = th.Ms(F)[0]
            meta, arr, par = mk_case(name_a1(shape, ah, F, M, dxdiv, True), shape, M, ah, F0=F, dxdiv=dxdiv)
            arr, ex = add_jstart(meta, arr, F, M, par["a"], par["h0"], par["U0"], par["b0"])
            row = run_one(meta["name"], meta, arr, par, "A1", extra=dict(supp=supp, jstart=True, **ex))
            emit(out, row)


def emit(out, row):
    with open(out, "a") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")
    print(row["case"], row["regime_sw"], row["regime_theory"], round(row["wall_s"], 1), flush=True)


A2_FR = [0.3, 0.45, 0.6, 0.8, 0.9, 1.0, 1.1, 1.3, 1.6, 2, 3]
A2_HZ = [0.3, 1, 3]
N_ = 0.01; H_ = 500.0; DELTA = 1500.0


def do_a2(out, hzs):
    for hz in hzs:
        h0 = H_ / hz
        for Fr in A2_FR:
            Usat = 5 * Fr
            U10, zs = th.u10_from_usat(Usat)
            U0 = th.u0_layer(U10, zs, h0)
            cd = th.cd_r1(h0)
            for rule, b0 in (("N2h0", N_ ** 2 * h0), ("N2delta", N_ ** 2 * DELTA)):
                name = f"A2_hz{hz}_Fr{Fr:.2f}_{rule}"
                mp = {"U10": U10, "N": N_, "z_i": h0, "dtheta": b0 * 290.0 / 9.81,
                      "rule": "docs/research/sw_charges/literature.md §7 R1"}
                a = H_ * math.sqrt(2) * math.exp(-0.5) / 0.3
                meta, arr, par = mk_case(name, "ridge", H_ / h0, None, U0=U0, h0=h0, b0=b0, cd=cd,
                                         forcing="balance", mapping=mp, H=H_, a=a, s=0.3)
                row = run_one(name, meta, arr, par, "A2", rule_b0=rule, Fr_game=Fr, N=N_, z_i=h0,
                              extra=dict(U10=U10, z_sat=zs, U_sat=Usat, cd=cd, out_of_scope=bool(a / h0 < 3)))
                emit(out, row)


if __name__ == "__main__":
    part = sys.argv[1]
    os.makedirs(RAW, exist_ok=True)
    out = os.path.join(RAW, f"rows_{part}.jsonl")
    if os.path.exists(out): os.remove(out)
    if part.startswith("a1"): do_a1(part, out)
    elif part == "a2a": do_a2(out, [0.3])
    elif part == "a2b": do_a2(out, [1, 3])
