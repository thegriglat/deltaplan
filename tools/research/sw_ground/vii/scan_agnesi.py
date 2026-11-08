"""Диагностика SWG-10 (не вариант): хребет Аньези H/L = 0,5 — отрыв интегрального слоя в зависимости от толщины
равновесного слоя δ0 (основной — Z_SAT = 500 м из фона; меньшие — только чтобы показать роль δ/L, U_∞ = bg_log(δ0));
ω = 0,5 (Davis & Carter 1986), без сглаживания δ*.
  py -m vii.scan_agnesi   → out/swg-10/agnesi_scan.json
"""
import time

import numpy as np

from ground import common as K
from wake import synth as S

from . import bl
from . import core as V

OMEGA = bl.OMEGA       # литературная релаксация Carter (сходится на Аньези при δ0 = 500 м), без сглаживания

OUT = K.SG / "out" / "swg-10"


def main():
    r = S.agnesi_run(ds_min=25.0, focus_x=np.arange(-600.0, 1201.0, 150.0), backend="numpy")
    rows = []
    for d0 in (500.0, 200.0, 100.0, 50.0, 25.0):
        t0 = time.time()
        for coupled in (False, True):
            vi = V.VII(r, delta0=d0, log=print, omega=OMEGA, d_smooth=0.0)
            res = vi.run_layer(coupled=coupled)
            st = vi.strips
            ic = int(np.argmin(np.abs(st.cvals)))
            L = res["layer"]
            xs = st.X[ic]
            lee = (xs > 0) & (xs < 1500)
            lf = V.LayerField(st, L, vi.z0)
            X = np.array([150.0, 300.0, 450.0, 600.0, 900.0])
            prof = {}
            for zz in (10.0, 50.0):
                z = r.panels.height(X, 0 * X) + zz
                pv = V.vii_parts(r, X, 0 * X, z, vi.sig_d if coupled else None, lf, vi.sig_u, vi.U_inf)
                prof[f"{zz:g}"] = (pv["speed"] * pv["upar_sign"] / vi.U_inf).tolist()
            sep = np.nonzero(lee & (np.nan_to_num(L["cf"][ic], nan=1) <= 0))[0]
            rows.append(dict(delta0=d0, coupled=coupled, converged=res["converged"], iters=len(res["hist"]),
                             H_max_lee=float(np.nanmax(L["H"][ic][lee])), cf_min_lee=float(np.nanmin(L["cf"][ic][lee])),
                             x_sep=float(xs[sep[0]]) if sep.size else None, x_reatt=float(xs[sep[-1]]) if sep.size else None,
                             inverse_nodes_lee=int((L["mode"][ic][lee] >= 1).sum()), u_over_Uinf_x=X.tolist(),
                             u_over_Uinf=prof, t_s=time.time() - t0))
            print(rows[-1], flush=True)
            K.dump_json(OUT / "agnesi_scan.json", dict(format="swg10-agnesi-scan", version=1, git=K.git_short(),
                                                       created=K.now_iso(), H=125.0, a=250.0, z0=r.z0, rows=rows, omega=OMEGA, d_smooth=0.0))


if __name__ == "__main__":
    main()
