---
type: "research"
status: "active"
module: "pullin-speed"
area: "flight"
updated: "2026-10-19"
summary: "VM-1: замеры полного «на себя» по 48 крыльям (подвеска, Kn, CL_α, CdA, ход, VG-прокси) и пары Vmax VG 0 / VG 100."
related: ["docs/research/pendulum/pullin-speed.md", "docs/contracts/pullin-speed.md", "docs/research/pendulum_pitch.md"]
conclusion: "(Vmax/Vтрим)² = 1 + k/Kn, k = 0,19 (0,11–0,25); паспортная Vmax требует Kn ≈ 0,047 (0,023–0,08) против 0,139 модели. Итог — docs/research/pendulum/pullin-speed.md."
data: "out/cases.json, out/wings_table.csv, out/wings_table.md, out/tables.md, out/summary.json, out/vg_pairs.csv, out/vg_pairs_summary.json, out/passport_censoring.csv"
applied_in: "—"
---
# Что ограничивает Vmax на полном «на себя» (VM-1): код и данные

Итог — `docs/research/pendulum/pullin-speed.md`. Код игры не менялся: `pullin_speed.gd` собирает `PendulumModel`
(как `tests/flight/pendulum/pendulum_sim.gd`) и правит только поля экземпляра; `configs/` не трогается.

## Воспроизведение (из корня копии, Godot 4.7.2; ≈ 10 мин на 8 процессов)
```
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD"); godot --headless --path . --import   # один раз
.dpcli/dpcli job start vm1-all 3000 tools/research/pullin_speed/run_all.sh      # 48 крыльев × 33 случая → out/raw_*.json, out/cases.json
.dpcli/dpcli job start vm1-extra 900 tools/research/pullin_speed/run_extra.sh   # случай pullcons → out/extra_*.json, снова merge.py
python3 tools/research/pullin_speed/analyze.py         # → out/wings_table.csv|md, out/tables.md, out/summary.json
python3 tools/research/pullin_speed/vg_pairs.py        # → out/vg_pairs.csv, out/vg_pairs_summary.json (из tools/research/data/wing_passports)
python3 tools/research/pullin_speed/passport_cens.py   # → out/passport_censoring.csv
```
Полный «на себя» — `pitch` −1 с рампой 6 с, 70 с, среднее за 50–70 с; штиль, ρ = 1,225, эталонная масса пилота.

## Случаи (`pullin_speed.gd`)
| ключ в `cases.json` | что |
|---|---|
| `base` | игра как есть |
| `hang+3`, `hang-3` | подвеска ±3 см (трим уходит) |
| `retrim±N` | подвеска на N см вперёд, `dcm0` (Cm0 паруса) подобран так, чтобы трим остался паспортным; `failed` — трим не найден |
| `cg25` | подвеска на 2,5 см впереди ЦМ модели масс, с подбором `dcm0` |
| `fmax` | предел силы рук 10⁶ Н |
| `slope0.9/1.1` | CL_α полос ±10 % с подбором `dcm0` |
| `cda0.5/2.0` | сопротивление пилота (CdA 0,21 м²) ×0,5 / ×2 (сопротивление полос пересчитывается: сумма по поляре сохраняется) |
| `wash0.5`, `dcm0x0.5`, `wash0.5_dcm0x0.5` | грубый прокси VG: крутка и/или Cm0 паруса ×0,5 без пересчёта трима (калиброванная модель VG — PB-2) |
| `pull0.60…1.20` | ход «на себя» 0,6…1,2 м при неограниченной силе рук — только как мера разрыва, не правка |
| `pullcons` | ход 0,335 м = 0,45·L/глубина штанги: момент как у сходящихся в ЦМ пилота линий сил |

## Данные и лицензии
Свои расчёты. Пары Vmax VG 0 / VG 100 и Vne — из `tools/research/data/wing_passports/wings_merged.json` (карточки DHV
Geräteportal https://service.dhv.de/db1/ и страницы производителей; числа с цитатами, PDF не храним — см. README набора).
Внешних данных в репозиторий не добавлено, `ASSETS.md` не затрагивается.
