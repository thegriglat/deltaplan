"""AM-09: наблюдаемые масштабов 2 и 3 из литературы без свободных параметров (проверка, вклад в χ²).

Определения — как в источниках:
  * термики: N_L·z_i/L — число термиков на линии длиной L на высоте 0,4 z_i (Lenschow & Stephens 1980,
    самолёт, все восходящие ядра по порогу влажности; Allen 2006 ур. 19): 1,2 ± 30 % (назн., calibration_data
    §0 п. 18). В модели: живые ядра на площадь n (стат. пробы AM-07б, tools/research/air_thermals/out/stats.json,
    круг 6 км, 4 ч) × поперечник ядра на 0,4 z_l (2·r₂(0,4), профиль Аллена модели) × z_l; z_l = R_верх/0,0765
    (радиус у верха модели — ровно 0,0765 z_l). Число на линии для случайных дисков = n·d.
  * болтанка: наклон спектра в инерционном интервале −5/3 (Колмогоров; разброс наклона в измерениях ±0,1 —
    Kaimal et al. 1972, назн.); модель — AM-08 (turb_probe.gd --only=spectrum, spectrum.py; ±2σ по 8 частям).
  * «шаг сильных термиков 1–1,5 z_i» (масштаб ячеек, Lenschow & Stephens 1980; Stull 1988) в модели тем же
    определением не считается: сила всех ядер — одна доля w* (нет порога «сильный»). В χ² не входит → «Границы
    модели».

  .venv/bin/python validate_s23.py → out/validate_s23.json
"""
from __future__ import annotations

import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
STATS = ROOT / "tools/research/air_thermals/out/stats.json"


def r2(zeta, zl):
    return max(10.0, 0.102 * zeta ** (1 / 3) * (1 - 0.25 * zeta) * zl)


def main():
    st = json.loads(STATS.read_text())
    rows = []
    for key, label in (("ongudai_d400_h12", "область 400 м, 12:00"), ("ongudai_d400_h15", "область 400 м, 15:00")):
        f = st[key]["field"]
        area = math.pi * (st[key]["radius_m"] / 1000.0) ** 2
        n = f["alive_mean"] / area * 1e-6                      # 1/м²
        zl = f["radius_top"]["mean"] / 0.0765
        zl_lo, zl_hi = f["radius_top"]["p10"] / 0.0765, f["radius_top"]["p90"] / 0.0765
        val = n * 2 * r2(0.4, zl) * zl
        # разброс по источникам: n·z_l² почти инвариантно (n_A ∝ 1/z_l²), берём ±1/4 размаха p10–p90 по z_l
        sig_m = 0.25 * abs(n * 2 * r2(0.4, zl_hi) * zl_hi - n * 2 * r2(0.4, zl_lo) * zl_lo) / 2
        rows.append(dict(scale=2, name=f"N_L·z_i/L на 0,4 z_i ({label})", data=1.2, sig_data=0.36, model=val,
                         sig_model=sig_m, n_per_km2=n * 1e6, z_l=zl,
                         src="Lenschow & Stephens 1980 (Allen 2006, ур. 19)"))
    for name, m, s2 in (("наклон спектра u, 150 м", -1.58, 0.13), ("наклон спектра w, 150 м", -1.70, 0.18),
                        ("наклон спектра u, 400 м", -2.00, 0.27), ("наклон спектра w, 400 м", -1.68, 0.15)):
        rows.append(dict(scale=3, name=name, data=-5 / 3, sig_data=0.1, model=m, sig_model=s2 / 2,
                         src="Колмогоров −5/3; разброс Kaimal et al. 1972; модель — AM-08 turb_probe/spectrum.py"))
    for r in rows:
        r["chi2"] = (r["model"] - r["data"]) ** 2 / (r["sig_data"] ** 2 + r["sig_model"] ** 2)
        print(f"{r['name']}: модель {r['model']:.2f} ± {r['sig_model']:.2f}, данные {r['data']:.2f} ± {r['sig_data']:.2f}, "
              f"χ² {r['chi2']:.2f}")
    (HERE / "out" / "validate_s23.json").write_text(json.dumps(rows, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
