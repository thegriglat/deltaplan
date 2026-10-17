---
type: "research"
status: "closed"
module: "pendulum"
area: "flight"
updated: "2026-10-17"
summary: "Тангаж «Маятника» на разгоне: скрипт замеров (pendulum_pitch.gd), разбор против точечной массы с полярой, фугоида; команды воспроизведения"
related: ["docs/research/pendulum_pitch.md"]
conclusion: "Итог — docs/research/pendulum_pitch.md; здесь код, данные и команды воспроизведения."
data: "out/game.json, out/summary.json, out/tables.md, out/longstep_*.json, out/phugoid_step.json, out/phugoid_long.json, fig/step_pull.png"
applied_in: "—"
---
# Тангаж «Маятника» на разгоне: код и данные

Итог и выводы — `docs/research/pendulum_pitch.md`. Игру не меняет: только чтение `PendulumModel`
(в замерах подменяются лишь поля экземпляра модели — инерция крыла, постоянная и предел рук — для
чувствительности).

## Воспроизведение (из корня копии, Godot 4.7.2)

```
export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
godot --headless --path . --import          # первый запуск в копии
O=tools/research/pendulum_pitch/out
# установившиеся режимы по ходу трапеции + переходы трим → «на себя» (≈ 1,5 мин)
godot --headless --path . res://tools/flight/pendulum_pitch.tscn -- --out=$O/game.json
# чувствительность: инерция крыла ×3, руки жёстче (τ 0,1 с)
godot --headless --path . res://tools/flight/pendulum_pitch.tscn -- --out=$O/game_iyy3.json --iyy_scale=3 --series=0
godot --headless --path . res://tools/flight/pendulum_pitch.tscn -- --out=$O/game_tau01.json --arms_tau=0.1 --series=0
# фугоида после ступеньки хода (120 с), варианты рук
for v in "base" "fmax1000 --arms_fmax=1000" "tau01 --arms_tau=0.1 --arms_fmax=1000"; do set -- $v
  godot --headless --path . res://tools/flight/pendulum_pitch.tscn -- --wings=training,laminar,sport \
    --long=-1,-0.5 --long_ramp=0 --long_s=120 --out=$O/longstep_$1.json $2 $3; done
# то же с рампой 6 с, 300 с (сырые long_*.json ≈ 3 МБ каждый, в git не кладутся — только сводка)
godot --headless --path . res://tools/flight/pendulum_pitch.tscn -- --long=-1,-0.5,-0.25 --out=$O/long_base.json
# разбор (numpy, matplotlib; подходит venv tools/research/heat_ca/.venv)
cd tools/research/pendulum_pitch
python analyze.py         # → out/summary.json, out/tables.md, fig/step_pull.png
python phugoid_step.py    # → out/phugoid_step.json
python phugoid_long.py    # → out/phugoid_long.json (нужны out/long_*.json)
```

## Файлы

| файл | что |
|---|---|
| `tools/flight/pendulum_pitch.gd` (+ `.tscn`) | замеры на `PendulumModel`: установившиеся режимы pitch +0,5…−1 (90 с, среднее 60–90 с), переходы трим → «на себя» (ступенька — мышь; 0,667 с — клавиатура `controls.json keyboard.pitch_rate_per_s` 1,5; рампы 3 и 6 с; ступенька и рампа 3 с на ход 1,6·V_трим), толчок по тангажу; режим `--long` — длинные ряды для фугоиды |
| `analyze.py` | эталон — точечная масса с полярой крыла (`configs/wings/<id>.json → polar`): (1) с CL(t) игры, (2) ступенька/рампы CL трим → CL(1,6·V_трим), Ланкастер |
| `phugoid_step.py`, `phugoid_long.py` | огибающая фугоиды игры против точечной массы при постоянном CL |
| `out/game.json` | сырые замеры (ряды каждые 0,05 с, 30 с) |
| `out/summary.json`, `out/tables.md` | сводка и таблицы для документа |
| `out/game_iyy3.json`, `out/game_tau01.json` | чувствительность (без рядов) |
| `out/longstep_*.json`, `out/phugoid_step.json` | фугоида после ступеньки, варианты рук |
| `out/phugoid_long.json` | фугоида при рампе 6 с, 300 с (сырьё `out/long_*.json` — локально, не в git) |
| `fig/step_pull.png` | θ, γ, α игры и γ точечной массы при ступеньке «на себя» 100 % |

## Источники и лицензии

Данные — собственные замеры модели игры (лицензия проекта). Поляры крыльев — из конфигов игры
(паспорта производителей и DHV, см. `configs/wings/*.json → polar._doc`). Литература — в документе
исследования; внешних наборов данных нет, в `ASSETS.md` добавлять нечего.
