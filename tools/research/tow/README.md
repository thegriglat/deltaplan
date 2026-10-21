---
type: "research"
status: "active"
module: "tow"
area: "flight"
updated: "2026-10-22"
summary: "Код и данные TW-16: статика пилота на тросе, опыты на PendulumModel, сверка; команды воспроизведения."
conclusion: "Статика (statics.py) и PendulumModel сходятся по ходу пилота на тросе ±0,06 м; упор Q3 задан скоростью и грудной уздечкой."
data: ["tools/research/tow/out/statics_table.csv", "tools/research/tow/out/compare.csv"]
applied_in: []
---
# TW-16: управляемость «Маятника» на тросе (продольный канал)

Исследование: [docs/research/tow/tow-control.md](../../../docs/research/tow/tow-control.md). Код игры не менялся.

## Состав

| Файл | Что |
|---|---|
| `statics.py` | Продольная статика (2D): крыло + пилот на стропе + трос с долей на пилота/киль, руки на штанге. Ньютон на numpy (без scipy). Калибровка по триму, `identify_cm` — Cm(α) модели из свободного полёта. Пишет `out/statics.json`, `out/statics_table.csv` |
| `extra.py` | Статика при больших T лебёдки (до 1300 Н) → `out/statics_extra.json` |
| `compare.py` | Сверка PendulumModel со статикой по установившимся точкам → `out/compare.csv` |
| `tow_sweep.gd`, `tow_sweep.tscn` | Опыты на `PendulumModel` без `TowLine`: сила/звено троса, пилот держит тангаж киля; режимы `SWEEP=TRIM|T|EPS|FORCE|PFIX|TV|T2` |
| `out/model_*.txt` | Сырой вывод `tow_sweep` (строки `CSV,{json}`) |

## Воспроизведение

Окружение: Godot 4.7.2, Python 3 + numpy. Один раз в копии: `godot --headless --path . --import` (с профилем `XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")`).

```bash
cd <копия>; export XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")
R=res://tools/research/tow/tow_sweep.tscn
SWEEP=TRIM godot --headless --path . $R > tools/research/tow/out/model_trim.txt        # свободный полёт, p = 0…-1
SWEEP=T AT=pilot EPS=20 godot --headless --path . $R > tools/research/tow/out/model_T_link_pilot.txt   # ≈ 2 мин
SWEEP=T AT=pilot EPS=45 godot --headless --path . $R > tools/research/tow/out/model_link_pilot_eps45.txt
SWEEP=FORCE AT=pilot EPS=20 godot --headless --path . $R > tools/research/tow/out/model_force_pilot.txt
SWEEP=FORCE AT=split EPS=20 godot --headless --path . $R > tools/research/tow/out/model_force_split.txt
SWEEP=PFIX PFIX=-1.0 EPS=45 godot --headless --path . $R > tools/research/tow/out/model_pfix_-1.0.txt
cd tools/research/tow && python3 statics.py && python3 extra.py && python3 compare.py
```

Каждый прогон Godot — 1–2 мин (50–70 с модели на точку); сценарий сам завершает работу (`quit`).
Выводные `CSV,` строки читаются `json.loads(line[4:])`. Окружение: `AT=pilot|hang|split`, `EPS` — угол троса, °, `VHOLD` — цель
воздушной скорости (PI пилота; **неустойчив**, в отчёте не используется), `PFIX` — постоянный ввод тангажа.

## Допущения (коротко; полно — в отчёте)

- Трос в «Маятнике» — звено XPBD к якорю на 300 м (EA = 3·10⁵ Н), якорь едет по курсу, высота — над пилотом на 300·sin ε;
  скорость якоря — П-регулятор по натяжению (`0,002 (м/с²)/Н`), слабого звена и срыва нет.
- Пилот держит тангаж киля (PI), пределы рук сняты (`free=true`: ход «на себя» 2 м, рука 10⁵ Н), чтобы измерить **потребное**, а не упор.
- Статика: линейная аэродинамика (a=4,54, α₀=−6,0°, CD=0,03+0,042·CL² по поляре трима), НТ на уровне киля; недостающая Cm(α) модели
  берётся из её свободного полёта (`identify_cm`) — сама проверка троса от этого не зависит.

## Источники и лицензии

BHPA Technical Manual (поправка 24), `BHPA_Tech_Manual_24.pdf` — в рабочей копии не коммитится, тексты — только выдержки с номером раздела.
Веб-источники (Wills Wing, Lookout Mountain, DHV, гл. «Источники» отчёта) — ссылки и короткие цитаты, данные не копировались.
Числа геометрии и аэродинамики — из `configs/wings/sport.json`, `configs/pendulum.json`, `scripts/flight/pendulum/*.gd` проекта.
Собственные таблицы `out/*` — данные расчёта, лицензия проекта.
