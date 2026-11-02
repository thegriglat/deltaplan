---
type: "research"
status: "active"
module: "trike-fix"
area: "flight"
updated: "2026-11-02"
summary: "TKF-7: кадры и числа TKF-К1 «после» правки вида тележки (TKF-4) тем же инструментом, что «до»"
data: ["tools/research/trike-fix/out_after/summary.json"]
related: ["docs/research/trike-fix/coupling.md", "docs/contracts/trike-fix.md", "tools/research/trike-fix/README.md", "tools/research/trike-fix/coupling_summary.md"]
---
# TKF-7: углы тележки к крылу «после» TKF-4

Сборка: копия `trike-fix/TKF-7` (от `feature/trike-fix`, содержит TKF-4). «До» — `tools/research/trike-fix/out/summary.json` и `build/screenshots/trike-fix/before/`; «после» — `out_after/summary.json` и `build/screenshots/trike-fix/after/`. Физика (`C_phys`, `bar_deg_phys`, `mast_normal_deg_max_phys`, `cart_phys_rate_*`) между прогонами не меняется, отличается только вид.

## Кадры
Моменты и ракурсы — те же, что «до» (`coupling_moments.json`): p1 `turn45_idle` 24,95 с, p2 `roll_pump` 18,6 с, p4 `reversal45` 21,35 с; ракурсы side / rear / front. Файлы `TKF-1_<p>_<ракурс>.png` (9 шт.) в `/home/greg/deltaplan/build/screenshots/trike-fix/after/`.

## Числа TKF-К1 до / после
Углы — градусы; `vis_lag` — отставание вида от физики; `mast` — `mast_normal_deg_max_vis`; `yaw` — max |`yaw_rel_deg_vis`|; `bar` — `bar_deg_vis` [min; max] (дуга штанги: −8,39 … +4,95).

| Сценарий | vis_lag до → после | mast до → после | yaw до → после | bar до → после |
|---|---|---|---|---|
| turn30_half | 0,9 → 0,1 | 4,0 → 4,0 | 0,7 → 0,0 | [3,79; 4,53] → [3,79; 4,53] |
| turn45_idle | 71,8 → 0,1 | 51,7 → 6,1 | 66,8 → 0,0 | [3,63; 70,59] → [3,79; 4,54] |
| reversal45 | 69,7 → 0,1 | 65,3 → 10,2 | 41,1 → 0,0 | [−3,64; 48,03] → [3,19; 4,53] |
| roll_pump | 143,3 → 0,1 | 131,6 → 11,0 | 160,1 → 0,0 | [0,28; 148,14] → [1,99; 5,13] |
| pitch_pump | 6,6 → 0,1 | 13,6 → 10,0 | 0,0 → 0,0 | [0,89; 16,4] → [0,89; 12,79] |
| push_full | 78,2 → 0,1 | 66,7 → 11,7 | 0,0 → 0,0 | [−63,87; 24,77] → [3,97; 14,5] |
| throttle_step | 14,2 → 0,1 | 12,8 → 1,7 | 0,0 → 0,0 | [−9,92; 4,54] → [3,79; 4,54] |

Полная таблица по всем сценариям (включая `turn45_full`, `reversal45_idle`, `roll_pump_idle`, `pitch_pump_2p0/3p2/4p0`) — `out_after/summary.json`; до — `out/summary.json`.

## Вывод
- `vis_lag_deg_max` во всех сценариях снизился до 0,056° (порог скачка колёса→воздух не нужен: отставание вида ≈ 0). Скрутка по рысканию (до 160°) и «тележка сквозь крыло» (mast до 132°) ушли.
- `mast_normal_deg_max_vis` теперь совпадает с физикой (`mast_normal_deg_max_phys`) и ≤ 12,3° во всех сценариях.
- Штанга в виде во всех сценариях, кроме `push_full` и `pitch_pump`, остаётся в дуге; на `push_full` вид (до 14,5°) совпадает с физикой (`bar_deg_phys`), выход за `push_deg` 4,95° — свойство физики, см. `coupling_summary.md`.
- Проверка: `check_summary.py tools/research/trike-fix/out_after/summary.json` → exit 0.

## Ограничения
- Замер — тот же `coupling_run.gd`, шаг 1/120 с, тяга по `configs/tow_tug.json`; внешних данных нет.
- Кадры снимались не headless (Vulkan, RTX 4070 SUPER); размеры PNG отличаются от «до» (другой кадр/ракурс), это не регрессия.
- Числа «до» и «после» — из разных сборок (до и после TKF-4); разница приписана правке вида, физика не менялась (проверено: `cart_phys_rate_dps_p99` совпадает во всех сценариях).
