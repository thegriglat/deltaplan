"""swc case ... / swc run ...  (python -m swpy)"""
import argparse
import json
import os
import sys

from . import case as swcase
from . import solver


def main(argv=None):
    ap = argparse.ArgumentParser(prog="swc", description="Решатель слоя мелкой воды (Рипа): случаи SW1, прогон -> SW2/SW3")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("case", help="создать случай SW1")
    ci = c.add_subparsers(dest="kind", required=True).add_parser("ideal", help="идеальная форма рельефа")
    ci.add_argument("--out", required=True, help="каталог")
    ci.add_argument("--name", required=True)
    ci.add_argument("--shape", default="ridge", choices=swcase.SHAPES)
    ci.add_argument("--dim", type=int, default=1, choices=(1, 2))
    ci.add_argument("--H", type=float, default=50.0, help="высота формы, м")
    ci.add_argument("--s", type=float, default=0.2, help="макс. крутизна (тангенс)")
    ci.add_argument("--nx", type=int, default=400)
    ci.add_argument("--ny", type=int, default=1)
    ci.add_argument("--dx", type=float, default=50.0)
    ci.add_argument("--dy", type=float)
    ci.add_argument("--h0", type=float, default=500.0)
    ci.add_argument("--b0", type=float, default=0.1)
    ci.add_argument("--U0", type=float, default=0.0)
    ci.add_argument("--V0", type=float, default=0.0)
    ci.add_argument("--cd", type=float, default=0.003)
    ci.add_argument("--f-cor", type=float, default=0.0)
    ci.add_argument("--h-min", type=float, help="по умолчанию 1e-3·h0")
    ci.add_argument("--b-min", type=float, default=1e-4)
    ci.add_argument("--forcing", choices=("balance", "none"), default="balance")
    ci.add_argument("--bc-x", default="farfield")
    ci.add_argument("--bc-y", default="periodic")
    ci.add_argument("--sponge-width", type=float, help="м; без — губки нет")
    ci.add_argument("--sponge-tau", type=float, default=600.0)
    ci.add_argument("--t-end", type=float, default=7200.0)
    ci.add_argument("--cfl", type=float, default=0.45)
    ci.add_argument("--steady-tol", type=float, default=1e-4)
    ci.add_argument("--avg-from", type=float)
    ci.add_argument("--out-every", type=float)
    ci.add_argument("--q-heat", type=float, help="поток тепла, Вт/м² (+ нагрев слоя), однородно")
    r = sub.add_parser("run", help="прогнать случай SW1 -> SW2 + SW3")
    r.add_argument("case", help="путь к <имя>.json")
    r.add_argument("--out", required=True)
    r.add_argument("--t-end", type=float, help="переопределить run.t_end")
    r.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "case":
        sp = None if a.sponge_width is None else (a.sponge_width, a.sponge_tau)
        meta, arrays = swcase.make_case(
            a.name, shape=a.shape, dim=a.dim, H=a.H, s=a.s, nx=a.nx, ny=a.ny, dx=a.dx, dy=a.dy, h0=a.h0, b0=a.b0,
            U0=a.U0, V0=a.V0, cd=a.cd, f_cor=a.f_cor, h_min=a.h_min, b_min=a.b_min, forcing=a.forcing,
            bc=(a.bc_x, a.bc_x, a.bc_y, a.bc_y), sponge=sp, t_end=a.t_end, cfl=a.cfl, steady_tol=a.steady_tol,
            avg_from=a.avg_from, out_every=a.out_every, q_heat=a.q_heat)
        print(swcase.write_case(a.out, meta, arrays))
        return 0
    log = None if a.quiet else (lambda s: print(s, file=sys.stderr))
    rec = solver.run_case(a.case, a.out, t_end=a.t_end, log=log)
    print(json.dumps({k: rec[k] for k in ("case", "status", "t", "steps", "wall_s", "mass_rel_err", "steady_residual", "dry_cells")},
                     ensure_ascii=False))
    return 0 if rec["status"] != "diverged" else 3
