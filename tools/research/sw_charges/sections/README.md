---
type: "research"
status: "active"
module: "sw-charges"
area: "air"
updated: "2026-11-08"
summary: "SWC-9: слой Рипа (swpy) против Пикара на разрезах cascade-2d C0–C4 и разрезе Perdigão: код, команды, время, где данные."
related: ["docs/research/sw_charges/stage1-sections.md", "docs/contracts/sw-charges.md", "tools/research/sw_charges/README.md"]
conclusion: "docs/research/sw_charges/stage1-sections.md"
data: "tools/research/sw_charges/out/sections/"
applied_in: ""
---
# sections: слой против Пикара на разрезах (SWC-9)

Вывод и таблицы — `docs/research/sw_charges/stage1-sections.md`. Здесь — код и воспроизведение.

## Файлы
- `run_sections.py` — C0–C4: случай SW1 (рельеф — блочное среднее h Пикара dx 50 по клетке слоя; ref по R1), прогон `swpy`, ū_P по SW5 v2, метрики, `out/sections/sections.{json,csv}` (SW5 v2), `profiles.npz`, PNG ū_SW и ū_P по x.
- `run_perd.py` — разрез Perdigão (NE-случай): линия вдоль ветра 60,7° через tse13 и tse04, рельеф `tools/research/cases/perdigao.py` (9 км, 10 м), `out/sections/perd.csv`, `perd_profiles.npz`.
- `make_tables.py` — таблицы для вывода (stdout).
- Чувствительность к порогу стационара: `out/sections/sections_tol5e-4.{json,csv}` (steady_tol 5e-4 вместо 1e-5).

## Воспроизведение (CPU, один поток, ≈ 30 с суммарно)
```
.dpcli/dpcli lock cpu swc9 -- tools/research/cascade_2d/py tools/research/sw_charges/sections/run_sections.py            # steady_tol 1e-5
.dpcli/dpcli lock cpu swc9 -- tools/research/cascade_2d/py tools/research/sw_charges/sections/run_sections.py --tol 5e-4 --suffix _tol5e-4
.dpcli/dpcli lock cpu swc9 -- tools/research/cascade_2d/py tools/research/sw_charges/sections/run_perd.py
python3 tools/research/sw_charges/contract/check_contract.py tools/research/sw_charges/out/sections
```
Интерпретатор — venv cascade_2d (нужен matplotlib и scipy; `swpy` — только NumPy). Время прогона слоя: 0,1–4,3 с на случай (1D, 32–64 клетки); весь набор из 30 строк SW5 — ≈ 40 с.
Сырьё SW1–SW3 (по каталогу на случай) — `~/data/sw_charges/sections/` и `…/sections_tol5e-4/` (≈ 1 МБ, вне git). Эталон Пикара — `$CASCADE2D_DATA` (`~/data/cascade_2d`, описание `out/cascade2d_refs.md`).

## Допущения
Физика слоя — R1 (`literature.md` §7): U0 — среднее степенного профиля (α 0,112 cascade-2d, z_sat по `max_profile`) по 0…h0; c_d = [κ/ln(0,37 h0/z0)]², z0 = 0,1 м; forcing balance, farfield + губка 1600 м (PERD 1000 м), θ0 = 300 К (как air3d). C3: q_heat = sun_flux(az 100°, el 45°) по уклону рельефа слоя (как `heated_slope`, формула `air3d/synth.py`), у краёв линейно до 0 на 2 км (taper Пикара); прогон 1 ч (главный, среднее за последние 30 мин) и 3 ч. Данные внешних источников не скачивались; лицензий данных нет (Perdigão — из репозитория, README данных).
