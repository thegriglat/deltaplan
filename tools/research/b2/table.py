"""Б2: таблица α / max_profile по часам, ветру и облачности для Онгудая (функция профиля C2 v4, эталон wind_prof.py)
и профиль ветра WindModel до/после на 10/50/100/300 м над рельефом. Сверка с rules.py (C10 v3) на контрольных входах.

    cd tools/research/air3d && $PY ../b2/table.py   # → ../b2/out/profile_table.md
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "air3d"))
sys.path.insert(0, str(HERE.parent / "cases"))
import real as R
import rules as RU
import wind_prof as WP

Z0, F_COR = 0.1, 1.13e-4          # z0 игры, f_cor решателя (AirCase.F_COR)
OLD_ALPHA, OLD_MAX = 0.14, 1.8    # до Б2: wind.shear_exponent, wind.max_profile_factor
ROUGH_FLOOR = 1.0                 # wind.roughness_height_m — пол профиля WindModel


def prof(agl, a, mp):
    return min((max(agl, ROUGH_FLOOR) / 10.0) ** a, mp)


def main():
    ctx = R.context("ongudai")
    lines = ["# Б2: α и max_profile для Онгудая (15 июля, часы места UTC+7)", "",
             f"α_N = {WP.alpha_n()}, z_sat_frac = {WP.z_sat_frac()}, z0 = {Z0} м, f = {F_COR} 1/с; "
             f"штиль — U10 = 0 (z_sat по нижнему пределу {WP.U10_MIN} м/с).", "",
             "| час | солнце, ° | облачность | U10, м/с | класс | α | z_sat, м | max_profile |", "|---|---|---|---|---|---|---|---|"]
    rows = []
    for hour in (6.0, 9.0, 12.0, 15.0, 20.0, 20.5, 21.0):
        for sky in ("clear", "partly", "overcast"):
            for u in (0.0, 3.0, 6.0):
                a, mp, cls, el = WP.for_hour(ctx, hour, sky, u, Z0, F_COR)
                zs = WP.z_sat(u, Z0, F_COR, WP.CLASSES.index(cls))
                rows.append((hour, sky, u, cls, a, mp, zs))
                lines.append(f"| {hour:g} | {el:.1f} | {sky} | {u:g} | {cls} | {a:.3f} | {zs:.0f} | {mp:.3f} |")
    lines += ["", "## Профиль WindModel: ветер / U10 на высоте над рельефом", "",
              f"До: α {OLD_ALPHA}, предел {OLD_MAX} → 10 м 1,000; 50 м {prof(50, OLD_ALPHA, OLD_MAX):.3f}; "
              f"100 м {prof(100, OLD_ALPHA, OLD_MAX):.3f}; 300 м {prof(300, OLD_ALPHA, OLD_MAX):.3f} (все часы и ветры).", "",
              "| час | облачность | U10 | класс | 10 м | 50 м | 100 м | 300 м | ветер на 300 м, м/с (до → после) |",
              "|---|---|---|---|---|---|---|---|---|"]
    for hour, sky, u, cls, a, mp, zs in rows:
        if u == 0.0:
            continue
        p = [prof(z, a, mp) for z in (10, 50, 100, 300)]
        lines.append(f"| {hour:g} | {sky} | {u:g} | {cls} | " + " | ".join(f"{v:.3f}" for v in p)
                     + f" | {u * prof(300, OLD_ALPHA, OLD_MAX):.1f} → {u * p[3]:.1f} |")
    lines += ["", "## Сверка с rules.py (C10 v3) на контрольных входах", "",
              "| α | U10 | z0 | f | z_sat rules | z_sat wind_prof | max_profile rules | max_profile wind_prof |", "|---|---|---|---|---|---|---|---|"]
    for a, u, z0, f in ((0.24, 3.0, 0.1, 1.13e-4), (0.112, 6.0, 0.1, 1.13e-4), (0.56, 3.0, 0.1, 1.13e-4),
                        (0.235, 8.8, 0.03, 1.23e-4)):
        lines.append(f"| {a} | {u} | {z0} | {f} | {RU.z_sat(u, z0, f):.6f} | {WP.z_sat(u, z0, f):.6f} | "
                     f"{RU.max_profile(a, u, z0, f):.9f} | {WP.max_profile(a, u, z0, f):.9f} |")
    out = HERE / "out" / "profile_table.md"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
