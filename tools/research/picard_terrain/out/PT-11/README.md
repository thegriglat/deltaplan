---
type: "research"
status: "active"
module: "picard-terrain"
updated: "2026-11-10"
summary: "PT-11: время поля и присутствие рельефа до/после срезанных клеток на dp-stand (формула, 4 места)."
conclusion: "Время загрузки в норме (макс. 1,15 на Онгудае, потоки 8); термики и тепло замкнуты; а разгон на гребнях в поле после слабее (медиана отношения (S-1) 0,69), слабый ротор у 2 гребней пропал."
data: "tools/research/picard_terrain/out/PT-11/"
applied_in: ""
---
# PT-11: время и присутствие поля со срезанными клетками

Итог — `summary.json`; обсуждение — `docs/research/picard_terrain_game.md`, раздел 7. Сырьё: `timing/*.jsonl`
(`dp-stand timing`), `presence/` (`plan_*`, `points_*`, `sample_*.csv`, `presence_*.json`), `thermals/*.jsonl`
(ядра), `heat_balance.json`. Таблицы: `timing.csv`, `presence.csv`, `thermals.csv`. Данные не внешние: места и случаи
из `tests/fixtures/wind` репозитория (лицензия репозитория).

«До» = коммит `f44c66b4a` (PT-9a + `timing`, до срезанных клеток), «после» = ветка `picard-terrain/PT-11` (с PT-10).

## Воспроизведение (всё под `.dpcli/dpcli lock cpu`)

```
git worktree add --detach ~/worktrees/deltaplan/picard-terrain-PT-11-base f44c66b4a
tools/research/picard_terrain/PT-11/build.sh            # dp-stand до/после, CARGO_TARGET_DIR=~/.cache/dp-target/PT-11-{base,after}
tools/research/picard_terrain/PT-11/build_probe.sh      # pt11-probe (ядра, баланс тепла) до/после, cargo --offline
python3 tools/research/picard_terrain/PT-11/run_timing.py     # 4 места x до/после x (3 повтора, потоки 8) + (1 повтор, потоки 2)
tools/research/picard_terrain/PT-11/run_post.sh         # ядра ongudai_day_1..3, баланс тепла, присутствие (весь набор гребней)
tools/research/picard_terrain/PT-11/run_mod.sh          # то же для умеренных гряд (PT11_SET=mod)
python3 tools/research/picard_terrain/PT-11/agg_timing.py
python3 tools/research/picard_terrain/PT-11/summarize.py
git worktree remove ~/worktrees/deltaplan/picard-terrain-PT-11-base
```

Что где: `terrain.py` — рельеф места из `places/*.bin`, поиск гребней по линии ветра; `presence.py` — план/выборка/свод;
`probe/` — отдельный крейт (path-зависимость на `rust/dp-air`, `rust/dp-stand`; `rust/` не менялся).
`run_mod.sh` остановлен после `synth_strong` (случай `ongudai_storm_mod` не считался — он только справочный).
