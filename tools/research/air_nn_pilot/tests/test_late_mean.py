#!/usr/bin/env python3
"""Цель «среднее поздних состояний» (П1 v3, NN-17): проверки генератора на случаях мини-набора lm_smoke.

Условия и предел — из плана lm_smoke (configs/dataset.yaml: max_outer 300, снимки 150, 200, 250, 300; места t_* П6).
1. Смешанный случай (h не сошлось — max, m сошлось): `solve_case(..., late=…, keep_snaps=…)`:
   - d400_h = среднее снимков, посчитанное здесь заново (np.mean по стопке), в пределах округления float16 (≤ 1 ulp);
   - late_spread60_p90 = независимый пересчёт (np.stack, без кода генератора) с точностью 1e-4 м/с;
   - снимки = продолжение счёта: снимок на итерации k побитно (float16) = решению v2 с max_outer = k (k = первый
     и последний снимки); последний снимок — конечное состояние v2;
   - d400_m (сошлось) и d400_hc/H/hbl — побитно как v2 (`solve_case(..., late=None)`) при том же пределе.
2. Сошедшийся случай (оба ok): все массивы побитно как v2.
3. Повтор смешанного случая: те же массивы и метаданные побитно; байты npz = файлу набора lm_smoke (если посчитан).

  .venv/bin/python tests/test_late_mean.py
GPU — под замком пилота (~2 мин). Итог — tests/out/late_mean.json.
"""
from __future__ import annotations

import io
import json
import os
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import dataset as DS  # noqa: E402

NAME = "lm_smoke"
MIXED, OK = "t_0001_000", "t_0002_001"   # по счёту lm_smoke 03.10: h max / m ok; оба ok


def bits(a):
    return a.view(np.uint16)


def eq16(a, b):
    return bool(a.dtype == b.dtype == np.float16 and a.shape == b.shape and np.array_equal(bits(a), bits(b)))


def within_ulp(a16, ref64):
    """a16 (float16) = ref64, округлённому в float16, с точностью 1 ulp float16."""
    r16 = ref64.astype(np.float16)
    d = np.abs(a16.astype(np.float64) - r16.astype(np.float64))
    tol = np.spacing(np.abs(r16)).astype(np.float64)
    return bool(np.all(d <= tol)), int(np.count_nonzero(~eq_mask(a16, r16)))


def eq_mask(a, b):
    return bits(a) == bits(b)


def spread_ref(snaps, edge):
    """Независимый пересчёт late_spread60_p90 (П1 v3)."""
    S = np.stack([s[:2] for s in snaps])                  # (n, 2, 13, ny, nx)
    a60 = S[:, :, 1] + 0.4 * (S[:, :, 2] - S[:, :, 1])    # 60 м: между 50 и 75 м
    d = a60 - a60.mean(axis=0)
    rms = np.sqrt(np.mean(np.sum(d ** 2, axis=1), axis=0))
    return float(np.percentile(rms[edge:-edge, edge:-edge], 90))


def main():
    cfg = DS.load_cfg(HERE / "configs/dataset.yaml")
    root = os.environ.get("AIR_NN_DATA") or cfg["data_root"]
    plan = DS.build_plan(cfg, NAME, root)
    sv = plan["solver"]
    mo = int(sv["max_outer"])
    late = dict(sv["late_mean"], edge_cells=sv["late_spread"]["edge_cells"])
    pts = sv["late_points"]
    conds = {c["id"]: c for c in plan["cases"]}
    import airlite_gen as G
    out, ok = dict(max_outer=mo, late=late, points=pts, checks={}), True

    def check(name, cond, info=None):
        nonlocal ok
        ok &= bool(cond)
        out["checks"][name] = dict(ok=bool(cond), **({"info": info} if info is not None else {}))
        print(f"{'ok  ' if cond else 'FAIL'} {name}" + (f"  {info}" if info is not None else ""), flush=True)

    t0 = time.time()
    with DS.GpuLock(DS.Stopper(False)):
        # 1. смешанный случай
        c = conds[MIXED]
        snaps = {}
        res, arr = G.solve_case(c, [], max_outer=mo, late=late, keep_snaps=snaps)
        r2, a2 = G.solve_case(c, [], max_outer=mo)                     # v2 при том же пределе
        rh, rm = res["runs"]["d400_h"], res["runs"]["d400_m"]
        check("mixed: статусы h=max, m=ok", rh["status"] == "max" and rm["status"] == "ok",
              {t: (res["runs"][f"d400_{t}"]["status"], res["runs"][f"d400_{t}"]["iters"]) for t in "hm"})
        check("mixed h: метаданные late_mean", rh["target"] == "late_mean" and rh["late_n"] == len(pts) == len(snaps["d400_h"])
              and rh["late_its"] == [p + 1 for p in pts],   # итерация снимка: первая проверка с it ≥ k (it = 1 + 10n)
              {k: rh[k] for k in ("target", "late_n", "late_its", "late_spread60_p90")})
        check("mixed m: метаданные final", rm["target"] == "final" and rm["late_n"] == 1 and rm["late_spread60_p90"] == 0.0)
        good, nd = within_ulp(arr["d400_h"], np.mean(np.stack(snaps["d400_h"]), axis=0))
        check("mixed h: d400_h = среднее снимков (≤ 1 ulp fp16)", good, dict(cells_not_bitwise=nd, total=arr["d400_h"].size))
        sp = spread_ref(snaps["d400_h"], late["edge_cells"])
        check("mixed h: late_spread60_p90 = пересчёт", abs(sp - rh["late_spread60_p90"]) < 1e-4,
              dict(gen=rh["late_spread60_p90"], ref=round(sp, 6)))
        check("mixed h: последний снимок = конечное состояние v2 (побитно)",
              eq16(snaps["d400_h"][-1].astype(np.float16), a2["d400_h"]))
        check("mixed h: среднее ≠ конечному состоянию", not eq16(arr["d400_h"], a2["d400_h"]),
              dict(max_abs=float(np.max(np.abs(arr["d400_h"].astype(np.float32) - a2["d400_h"].astype(np.float32))))))
        for k in ("d400_m", "d400_hc", "d400_H", "d400_hbl"):
            check(f"mixed: {k} побитно как v2", eq16(arr[k], a2[k]))
        check("mixed: статусы/итерации как v2",
              all((res["runs"][t]["status"], res["runs"][t]["iters"]) == (r2["runs"][t]["status"], r2["runs"][t]["iters"])
                  for t in ("d400_h", "d400_m")))
        _, a1 = G.solve_case(c, [], max_outer=pts[0])                  # продолжение: снимок k = решение с пределом k
        check(f"mixed h: снимок {pts[0]} = решение v2 с max_outer={pts[0]} (побитно)",
              eq16(snaps["d400_h"][0].astype(np.float16), a1["d400_h"]))
        # 2. сошедшийся случай
        c = conds[OK]
        res_ok, arr_ok = G.solve_case(c, [], max_outer=mo, late=late)
        _, arr_ok2 = G.solve_case(c, [], max_outer=mo)
        check("ok: оба решения final", all(res_ok["runs"][t]["target"] == "final" for t in ("d400_h", "d400_m")),
              {t: (res_ok["runs"][t]["status"], res_ok["runs"][t]["iters"]) for t in ("d400_h", "d400_m")})
        check("ok: все массивы побитно как v2", list(arr_ok) == list(arr_ok2) and all(eq16(arr_ok[k], arr_ok2[k]) for k in arr_ok))
        # 3. повтор
        c = conds[MIXED]
        res_b, arr_b = G.solve_case(c, [], max_outer=mo, late=late)
        strip = lambda r: {t: {k: v for k, v in d.items() if k not in ("t_solve", "t_init")} for t, d in r["runs"].items()}  # noqa: E731
        check("повтор: массивы побитно", list(arr) == list(arr_b) and all(eq16(arr[k], arr_b[k]) for k in arr))
        check("повтор: метаданные решений те же", strip(res) == strip(res_b))
    buf = io.BytesIO()
    DS.write_npz(buf, arr)
    L = DS.Layout(cfg, root, NAME)
    f = L.case_file(MIXED)
    if f.exists():
        check("повтор: npz = файлу набора lm_smoke (побитно)", buf.getvalue() == f.read_bytes(), str(f))
    else:
        out["checks"]["npz_vs_dataset"] = dict(ok=None, info=f"нет {f} — набор lm_smoke не посчитан")
    out.update(ok=ok, t_s=round(time.time() - t0, 1), solver_version=DS.solver_version(), cases=[MIXED, OK])
    p = HERE / "tests/out/late_mean.json"
    p.parent.mkdir(exist_ok=True)
    p.write_text(json.dumps(out, ensure_ascii=False, indent=1, default=float) + "\n")
    print("ИТОГ:", "ok — цель П1 v3 (среднее поздних) верна" if ok else "ПРОВАЛ", f"({out['t_s']} с)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
