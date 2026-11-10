---
type: "research"
status: "closed"
module: "lee-turb"
area: "air"
updated: "2026-11-10"
summary: "LT-11: разложение σ в точке test_lee_zone_all_starts по ветвям модели (зонд Godot)"
related: ["docs/research/lee_turb.md"]
conclusion: ""
data: ""
applied_in: ""
---

# lee_turb/leezone — LT-11: разложение σ в точке test_lee_zone_all_starts

Отчёт: `docs/research/lee_turb/leezone.md`. Данных извне нет (рельеф мест игры — `ASSETS.md`, Copernicus DEM, `licenses/copernicus-dem.txt`); формулы — `rust/dp-air/src/terms/turb/`.

| файл | что |
|---|---|
| `probe_tail.gd.part`, `make_probe.sh` | зонд Godot: хвост дописывается к началу `tests/atmosphere/test_ridge_starts.gd` → `tests/atmosphere/probe_lee.gd` в копии (в основную копию не кладётся) |
| `run_probe.sh <копия> <лог> [старт,…]` | прогон всех стартов (`--ridge-full`); `LT11_XDG` — имя профиля |
| `build_old.sh` | сборка `dp-gd` на `470745ac8` (main до срезанных клеток) |
| `branches.py` | пересчёт ветвей σ_u по каналам поля (формулы `sigma.rs`, `sep.rs`, LTM v1) |
| `analyze.py <лог> --tag ltm\|old` | `out/starts*.csv`, `profiles*.csv`, `grid*.csv`, `scan_points*.json` |
| `cross.py` | `out/cross.csv`: поле × точка |
| `out/raw_*.txt` | сырые строки зонда (JSON) |

## Воспроизведение
```bash
git worktree add --detach ~/worktrees/deltaplan/lee-turb-LT-11-ltm aff9d1731      # LTM v1 финальный (LT-9 в feature/lee-turb 12078ad)
tools/research/lee_turb/leezone/build.sh ~/worktrees/deltaplan/lee-turb-LT-11-ltm LT-11-ltm   # dp-gd -> libdp_air_tune.so
git worktree add --detach ~/worktrees/deltaplan/lee-turb-LT-11-old 470745ac8 && tools/research/lee_turb/leezone/build_old.sh   # либо build.sh <копия> LT-11-old
.dpcli/dpcli job --lock cpu start LT-11-full 10000 tools/research/lee_turb/leezone/run_probe.sh ~/worktrees/deltaplan/lee-turb-LT-11-ltm $PWD/tools/research/lee_turb/leezone/out/logs/full_ltm2.log
LT11_XDG=lee-turb-LT-11-old .dpcli/dpcli job --lock cpu start LT-11-fullold 10000 tools/research/lee_turb/leezone/run_probe.sh ~/worktrees/deltaplan/lee-turb-LT-11-old $PWD/tools/research/lee_turb/leezone/out/logs/full_old2.log
cd tools/research/lee_turb/leezone && python3 analyze.py out/logs/full_ltm2.log --tag ltm && python3 analyze.py out/logs/full_old2.log --tag old && python3 cross.py
```
Время: ≈ 5 мин на старт на поле (3 атмосферы), 10 стартов ≈ 50 мин на 1 слот cpu. `out/logs/` не в git.

## Границы
Один сид (4242), момент 12 ч, июль; ветви пересчитаны (σ_rec против игры ≤ 0,11 %), `relief` — прямой опрос земли, не узел аналитики. Подробнее — в отчёте.

После приёмки копии `lee-turb-LT-11-ltm`, `-old` и цель `~/.cache/dp-target/LT-11-*` снимаются (`git worktree remove`); создаются заново командами выше.
