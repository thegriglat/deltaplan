---
type: "research"
status: "active"
module: "sw-charges"
area: "air"
updated: "2026-11-08"
summary: "SWC-12: панели и вихри panels2d против труб Lubitz–White, мачт Perdigão и Пикара (C1, C2, C4) на 2D-разрезах: код, команды, время, данные."
related: ["docs/research/sw_charges/stage2-2d.md", "docs/contracts/sw-charges.md", "tools/research/sw_charges/README.md"]
conclusion: "docs/research/sw_charges/stage2-2d.md"
data: "tools/research/sw_charges/out/panels2d/"
applied_in: ""
---
# panels_exp: панели и вихри против эталонов (SWC-12)

Вывод и таблицы — `docs/research/sw_charges/stage2-2d.md`. Здесь — код и воспроизведение. Библиотека `panels2d` (SW6 v2) не менялась.

## Файлы
- `common.py` — чтение Пикара F1 (центры клеток, степенной закон у стенки), гребни, точки отрыва (уклон ≥ 0,27), цикл МДВ с осреднением, ротор.
- `run_case.py <case>` — один случай → `out/panels2d/cases/<case>[tag].json` (строки SW7, rotor, служебное). Случаи: C1 C2 C4 PERD_NE PERD_SW LW_H3 LW_MD LW_UCD LW_H5 LW_GI LW_H8. Опции: `--ds`, `--smooth` (σ сглаживания DSM Perdigão), `--tag`, `--no-vortex`.
- `run_all.sh` — все случаи + чувствительность (3 процесса параллельно, BLAS в 1 поток).
- `merge.py` — `out/panels2d/points.{json,csv}` (SW7), `info.json`, `tables.md`, `scatter.png`, `rotor_lines.png`.

## Воспроизведение
```
.dpcli/dpcli lock cpu swc12 -- bash tools/research/sw_charges/panels_exp/run_all.sh        # ≈ 1 ч CPU-времени суммарно
OPENBLAS_NUM_THREADS=1 tools/research/cascade_2d/py tools/research/sw_charges/panels_exp/merge.py
python3 tools/research/sw_charges/contract/check_contract.py tools/research/sw_charges/out/panels2d
```
Интерпретатор — venv cascade_2d (numpy, scipy, matplotlib). Данные: Пикар `~/data/cascade_2d/fields/<C>/picard_none_d50.json` (описание `out/cascade2d_refs.md`), Perdigão — `tools/research/cases/perdigao.py` и `tools/research/data/perdigao/` (ISFS NCAR/EOL; Menke 2019, CC BY 4.0). Трубные числа Lubitz & White 2007 — из `docs/research/calibration_data/slope-flow.md` §2.2; данные из внешних источников не скачивались, новых файлов данных нет, лицензий не добавлено.

## Постановка (как в карточке)
- Потенциал: `build_panels(ds_min=25, x_focus=гребень)`, `bg_profile(U10, α, z_sat, smooth_m = 250)`; вихри: `step` с точкой рождения за каждым гребнем (заметность ≥ 60 м) в первой точке вниз по потоку, где подветренный уклон (база 40 м) ≥ 0,27 (Finnigan 1988); ниже порога — вариант vortex = potential (`shed = false`). dt = 0,5·ds_min/max|V| (потенциальное решение на ds_min/2 над землёй); разгон 3 пролёта (пролёт = длина области от первого гребня до границы / U(50 м)), осреднение u, w по следующим 2 пролётам каждого шага. Вихри за границей области (x_end), выше гребня + 1500 м или на 1000 м вверх по потоку от первого гребня — удаляются (учёт `lost`).
- Столбец `err` — u_pan − u_ref; `t_solve_ms` — прямое решение N×N; `t_query_us` — мкс на точку; для vortex также `t_step_ms`, `n_vortices`, `drift_u` (макс. разность осреднённого u по двум половинам окна осреднения, м/с).
- Ротор: u < −0,5 м/с на z_agl = 15 м (порог и слепая зона Menke 2019), длина самого длинного участка > 50 м между главным гребнем и следующим (или границей). У Пикара — то же по полю F1.

## SWC-16 (круг 2): скан труб и эталон Пикара по центрам клеток
Вывод — `docs/research/sw_charges/stage2-2d-tunnel.md`. SW7 `out/panels2d/points.{json,csv}` пересобран `merge2.py`; прежний (SWC-12) — `out/panels2d/prev_swc12/` (points, info, tables, рисунки).
- `scan_lw.py`, `scan_lw_extra.py` — скан факторов ΔS (профиль, σ сглаживания, форма, высота, определение ΔS, ds_min) → `out/panels2d/tunnel/scan_lw{,_extra}.json` (секунды).
- `run_cc.py <C1|C2|C4|LW_x>` — C1/C2/C4 с эталоном по центрам клеток F1 (`cases/<C>_cc.json`), LW с однородным фоном (`cases/LW_x_uni.json`); `run_cc_all.sh` — все (≈ 25 мин, 3 процесса).
- `ref_err.py` — погрешность P50 (P100↔P50 и P200↔P100 через осреднение 2×2) → `tunnel/picard_err.json`.
- `merge2.py` — сборка SW7 и `tables.md`. Рисунки SWC-12 `scatter.png`, `rotor_lines.png` перенесены в `prev_swc12/` (с новым набором не пересчитывались).
```
OPENBLAS_NUM_THREADS=1 tools/research/cascade_2d/py -I tools/research/sw_charges/panels_exp/scan_lw.py && ... scan_lw_extra.py
.dpcli/dpcli lock cpu swc16 -- bash tools/research/sw_charges/panels_exp/run_cc_all.sh
tools/research/cascade_2d/py -I tools/research/sw_charges/panels_exp/ref_err.py
tools/research/cascade_2d/py -I tools/research/sw_charges/panels_exp/merge2.py
python3 tools/research/sw_charges/contract/check_contract.py tools/research/sw_charges/out/panels2d
```
Данные: Пикар `~/data/cascade_2d/fields/` (как выше); труба — PDF Lubitz & White 2007 (UC Davis, открытый доступ, только прочитан: геометрия, определение ΔS, α, табл. 2; файлов данных не добавлено, лицензий нет).

## SWC-17 (круг 3): пограничный слой и отрыв Хеда
Вывод — `docs/research/sw_charges/stage2-2d-bl.md`. SW7 v2 `out/panels2d/points.{json,csv}` (version 2: 4 варианта, `ref_err`, `within_tol_ref`); прежний (SWC-16, version 1) — `out/panels2d/prev_swc16/points_v1.json.gz` (gzip, чтобы контрактный тест не проверял его как текущий); `prev_swc12/points.json` так же упакован.
- `bl_common.py` — `run_bl_variants`: potential_bl (`surface_flow` → `boundary_layer` → `velocity_bl`) и vortex_bl (`step(shed="auto")`, `velocity_bl` с вихрями на каждом шаге окна); библиотека `panels2d` не менялась.
- `run_bl.py <C1|C2|C4|PERD_NE|PERD_SW|LW_x> [H для LW, м | z0 для PERD]` → `cases/<case>_bl[...].json`. Случаи C*/PERD вызывают прежние `run_cc.case_cc` / `run_case.case_perd` с подменой `run_variants`; LW — масштабированный хребет (H = 21,1 м при z0 = 0,1 м: z0/H трубы 0,18 мм/38 мм), см. вывод.
- `run_bl_all.sh` — все случаи + чувствительность LW (H = 50, 150 м); Perdigão с z0 = 0,1 м — строка в комментарии конца скрипта.
- `merge3.py` — SW7 v2, `tables.md`, `parity.json`, `info.json`.
```
.dpcli/dpcli lock cpu swc17 -- bash tools/research/sw_charges/panels_exp/run_bl_all.sh      # ≈ 33 мин CPU суммарно
OPENBLAS_NUM_THREADS=1 tools/research/cascade_2d/py -I tools/research/sw_charges/panels_exp/merge3.py
python3 tools/research/sw_charges/contract/check_contract.py tools/research/sw_charges/out/panels2d
```
Данные и лицензии — как в SWC-12/16; новых внешних файлов нет. Эталон погрешности — `out/panels2d/tunnel/picard_err.json` (SWC-16).

## SWC-19 (круг 4, последний): Jackson–Hunt и отрыв с подветренной
Вывод — `docs/research/sw_charges/stage2-2d-jh.md`. SW7 v3 `out/panels2d/points.{json,csv}` (version 3: 6 вариантов, добавлены `potential_jh`, `vortex_jh`); прежний (SWC-17, v2) — `out/panels2d/prev_swc17/` (`points_v2.json.gz`). Библиотека `panels2d` (SW6 v4) не менялась.
- `jh_common.py` — `run_jh_variants`: potential_jh (`velocity_jh`) и vortex_jh (`step(shed="auto")`, отрыв Хеда с `lee_only`, u = `velocity_jh` + вклад вихрей: `velocity_jh` вихрей не принимает, вклад добавляется как разность `velocity` с вихрями и без).
- `run_jh.py <case>` → `cases/<case>_jh.json`; `run_jh_all.sh` — все 11 случаев (3 процесса, ≈ 41 мин CPU суммарно); `merge4.py` — SW7 v3, `tables.md`, `parity.json`, `info.json`.
```
.dpcli/dpcli lock cpu swc19 -- bash tools/research/sw_charges/panels_exp/run_jh_all.sh      # Perdigão требует scipy: PY=tools/research/cascade_2d/py (по умолчанию в скрипте)
OPENBLAS_NUM_THREADS=1 tools/research/cascade_2d/py -I tools/research/sw_charges/panels_exp/merge4.py
python3 tools/research/sw_charges/contract/check_contract.py tools/research/sw_charges/out/panels2d
```
Данные и лицензии — как в SWC-12/16/17; новых внешних файлов нет.
