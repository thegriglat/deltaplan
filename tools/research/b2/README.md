# Б2: α и λ в игре — профиль притока по устойчивости, пересчёт эталонов и цена

Записка — `docs/archive/plan/air-model-b2.md`. Функция профиля — `scripts/atmosphere/wind_profile.gd` (игра) и
`tools/research/air3d/wind_prof.py` (эталон), контракт C2 v4.

| файл | что |
|---|---|
| `table.py` | α / класс / z_sat / max_profile для Онгудая по часам, ветру и облачности (эталон), профиль WindModel до/после, сверка с `rules.py` → `out/profile_table.md` |
| `game_profile.gd`, `.tscn` | то же из игры (WindProfile, WindModel) → `out/game_profile.txt` |
| `regen.sh` | пересчёт фикстур `picard/`, `window/`, `ref/` генераторами air3d (CuPy, под замком GPU) |
| `bench.sh` | GPU-тесты `test_air_` и bench Пикара 400/200 м (QUICK и полный) → `out/bench/<метка>_*.log` |
| `headless.sh` | все headless-тесты по папкам → `out/headless/<метка>_<папка>.log` |
| `cost.py` | таблица цены до/после из логов bench и GPU-тестов → `out/cost.md` |
| `tke_recheck.py` | ТКЭ Askervein масштаба 3 (метод AM-09б) с λ/h 0,0158 и профилем Б1 → `out/tke/` (поля — `fields/`, вне git) |
| `split.py` | откуда рост итераций: профиль притока или λ/h (эталон air.py, 4 набора) → `out/split.md` |

```bash
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
cd tools/research/air3d && $PY ../b2/table.py
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/research/b2/game_profile.tscn
/home/greg/deltaplan/tools/job.sh start b2-regen 7200 tools/research/b2/regen.sh
# «до» — копия на базовом коммите (git worktree + .godot), «после» — эта копия
/home/greg/deltaplan/tools/job.sh start b2-base 7200 tools/research/b2/bench.sh base <копия на базе>
/home/greg/deltaplan/tools/job.sh start b2-after 7200 tools/research/b2/bench.sh b2
python3 tools/research/b2/cost.py base b2
cd tools/research/air3d && flock /tmp/heat_ca_gpu.lock $PY ../b2/split.py
/home/greg/deltaplan/tools/job.sh start b2-headless 3600 tools/research/b2/headless.sh after1
```

`bench.sh` запускает Godot с `--disable-vsync --max-fps 60`: при погашенном мониторе (DPMS) vsync X11/NVIDIA
даёт ~1 кадр/с, а задачи решателя опрашиваются раз в кадр — стена и таймауты 60 с теряют смысл. 60 кадров/с —
как у включённого монитора. Итерации от этого не зависят.
