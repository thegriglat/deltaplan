# Случай Perdigão (А4) — C10 v1 → v2 (Б1)

**Б1 (01.10.2026):** модуль приведён к C10 v2 — общая схема `../scheme.py`, сетка/область/губки/профиль притока по
общим правилам `../rules.py` (dx 30 м, область 6 км, потолок 1748 м над нулём, губки 1050 м / от высшей точки рельефа,
max_profile по z_sat = 0,3·h), U10 фона по правилу «модель на опорной точке = данные» (NE 3,27, SW 3,12 м/с), на мачтах —
компонента вдоль притока u_∥/S_ref (`MAST_OBS`), σ сетки/устойчивости — `../b1/out/grid.json`. Пробный прогон А4 ниже
(`trial.py`, `out/trial_runs.jsonl`, 1-й порядок, k_relax 0,5) — история, по v2 не проходит; контроль v2 — `../b1/`.

Модуль случая калибровки `tools/research/cases/perdigao.py` (`NAME = "pd"`, `SUBCASES = ["ne", "sw"]`) и его
скрипты. Постановка, решения и границы — `docs/archive/plan/air-model-a4.md`. Контракт — `docs/contracts/air-model.md`,
«C10 v1». Решатель (`tools/research/air3d/air.py`, `solver.py`) не менялся.

| Файл | Что |
|---|---|
| `../perdigao.py` | модуль C10: рельеф/лес/входы, `observations()`, `run_one(over, subcase, dx)` |
| `terrain.py` | DSM Copernicus GLO-30 и доля леса WorldCover конвейером игры (`tools/terrain/fetch_dem.py`, `fetch_landcover.py`), мачты PT-TM06 → кадр игры, сверка высот → `out/terrain10.npz`, `out/masts.csv`, `out/terrain_check.md` |
| `trial.py` | пробный прогон (номинал, dx 20/30/40, z0 0,1/1,8, без смещения d, λ/h 0,25) → `out/trial_runs.jsonl`, `out/grid_sigma.json` |
| `table.py` | таблица модель против данных → `out/trial_table.md` |
| `figs.py` | картинки → `out/fig_terrain.png`, `out/fig_section_{ne,sw}.png`, `out/fig_obs.png`, `out/section_{ne,sw}.npz` |
| `out/` | всё выше; крупного нет (`terrain10.npz` 0,9 МБ), вне git ничего не хранится |

## Воспроизведение
Из `tools/research/cases` (venv калибровки с CuPy; для рельефа нужны ещё `brotli tifffile imagecodecs pyproj`,
для профилей — только csv из git):
```bash
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
uv pip install --python $PY brotli tifffile imagecodecs pyproj          # один раз
cd perdigao
$PY terrain.py                      # сеть: тайлы Copernicus N39W008 и WorldCover N39W009 (кеш ~/.cache/deltaplan_terrain)
/home/greg/deltaplan/tools/job.sh start a4-trial 4000 $PY trial.py      # 14 прогонов; ~25 мин при занятом GPU
$PY table.py; $PY figs.py
cd ..; $PY check_c10.py perdigao perdigao/out/trial_runs.jsonl          # контрактный тест, без GPU
```
Один прогон из Python: `import perdigao as P; P.run_one({"lam_frac": 0.05}, "ne", 30.0)` → строка C10
(`params` — все поля `air.Params` как применены; `obs` — все наблюдаемые подслучая; замок GPU — на прогон).

## Что в `over`
Любое поле `air.Params`. Постоянные случая: `max_profile` 2,5, `f_cor` 9,3·10⁻⁵ (39,7° с. ш.), `sponge_side_m` 1000,
`sponge_top_m` 700, γ = 0 (нейтраль), без нагрева; по умолчанию `lam_frac` 0,031, `alpha` 0,235 (перекалибровка
Askervein), `z0` = `perdigao.z0_nominal()` (0,645 м), `pr_t` 0,85, `local_k` True и т.д. (`Params()`).
Смещение под пологом d = 12,6 м × доля леса — часть рельефа (`perdigao.D_DISP`), не параметр `over`.

## Данные и лицензии
- Мачты ISFS (NCAR/EOL, doi:10.26023/ZDMJ-D1TY-FG14; «Data provided by NCAR/EOL under the sponsorship of the National
  Science Foundation»), раскладка — Palma et al. 2018 «Perdigão-2017: experiment layout» (NEWA), зона рециркуляции —
  Menke et al. 2019, ACP 19, 2713, doi:10.5194/acp-19-2713-2019 (CC BY 4.0). Подробнее — `tools/research/data/perdigao/README.md`.
- Рельеф — Copernicus DEM GLO-30: «produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space
  GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA».
- Лес — ESA WorldCover 2021 v200: «© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021)
  processed by ESA WorldCover consortium», CC BY 4.0.
- `out/terrain10.npz`, `out/masts.csv` — производные от них (строка в `ASSETS.md`).
