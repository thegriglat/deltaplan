---
type: "research"
status: "active"
module: "air-cascade"
updated: "2026-10-24"
conclusion: "Экспорт воспроизводит фикстуру: итерации 191/231/201/131, поле у старта до 5e-7 м/с"
data: "~/data/air_cascade/ongudai/ (вне git, 4×38 МБ)"
applied_in: ""
summary: "AC-R2: Онгудай 400 м в формате R1 из air.py (f64), 4 случая; итерации совпали с фикстурой (разница 0)"
---
# Экспорт Онгудая 400 м в формат R1 (AC-R2)

Случай: Онгудай, область 38,4 км, сетка 96×96×50 (dx 400 м, dz 105 м, z_bot 420 м), 12:00, ветер с 150°,
z_i 3362 м. Эталон — `tools/research/air3d/air.py` (CuPy, float64, критерий 2e-5 / 5e-7 / 1e-6, проверка
каждые 10 итераций), путь решения как у `picard_gpu_refs.solve`. Формат — R1 v1
(`docs/contracts/air-cascade.md`): постоянный вход после подготовки `Air`, решение `sol_*` после
`finalize`, `history`, `criterion`, `params`, `case_params`, `mg_levels_xyz`, `source`, `crop`, `t_ref_s`;
блоков одной итерации нет. Упаковка (`Pack`, порядок) — из `air3d/fixtures.py`.

## Воспроизведение
```
cd tools/research/heat_ca && uv venv .venv && uv pip install --python .venv/bin/python -r requirements.txt && cd -
tools/research/heat_ca/.venv/bin/python tools/research/air_cascade/export/export_ongudai.py   # ~1 мин, RTX 4070 SUPER
python3 tools/research/air_cascade/picard_rs/contract/check_contract.py --ref ~/data/air_cascade/ongudai/*.json
```
Выход — `$AIR_CASCADE_DATA/ongudai/` (по умолчанию `~/data/air_cascade/ongudai/`, вне git). Запись во
временный файл и переименование. Код выходит с 1, если итерации расходятся с фикстурой более чем на 10
или поле у старта вне допуска.

## Результат
| случай | итерации экспорта | итерации фикстуры | t_ref_s | размер .bin |
|---|---|---|---|---|
| ongudai_d400_u3_heat | 191 | 191 (f64) | 9,12* | 38,3 МБ |
| ongudai_d400_u3_mech | 231 | 231 (f64) | 4,43 | 38,3 МБ |
| ongudai_d400_u0_heat | 201 | 201 (f32) | 4,81 | 38,3 МБ |
| ongudai_d400_u6_heat | 131 | 131 (f32) | 3,12 | 38,3 МБ |

\* первый случай включает прогрев CuPy (компиляция ядер); `t_ref_s` = `wall − t_check` решения (без
проверок невязки), справочно, RTX 4070 SUPER. Для 0 и 6 м/с в фикстуре есть только f32, f64-экспорт совпал.
Максимальная разница итераций — 0 (допуск 10).

Поле у старта (crop i0 58, j0 39, n 16; центры клеток; u3_heat с `w_mech` из u3_mech, `w_conv = w − w_mech`)
против `crop_*` фикстуры: max |Δ| u 2,4e-7, v 4,8e-7, w_mech 6e-8, w_conv 3e-8 м/с (допуск 1e-3·u_scale =
6e-3), θ′ 3e-8 К (допуск 0,05) — совпадение на уровне float32-округления.

## Допущения и границы
- Слоя рельефа `data/terrain/ongudai` в копиях нет, поэтому вход собран из массивов фикстуры: `hc`, `H`
  (до гашения у края, делает сам `Air`), `gam` (в центрах уровней) — они хранятся в float32, исходный
  float64 не восстановить; `params` и `profiles[U10]` (alpha, max_profile) — из JSON (assert: равны
  умолчаниям `Params`, `dtau_u` 120 м). Итерации совпали, значит влияние округления входа ничтожно.
- «mech» — тот же случай с H = 0, холодный старт (`Q = 0`).
- Источники/лицензии: код и фикстура — репозиторий; рельеф Онгудая — DEM проекта (см. `ASSETS.md`); внешних
  данных не добавлено.
