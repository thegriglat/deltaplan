---
type: "research"
status: "active"
module: "tow"
area: "flight"
updated: "2026-10-22"
summary: "Код и данные TW-16: статика пилота на тросе, опыты на PendulumModel, сверка; команды воспроизведения."
conclusion: "Статика и PendulumModel (трос лебёдки вперёд-вниз) сходятся по ходу пилота ±0,04 м; упор Q3 даёт рост скорости при удержании тангажа, а не момент троса."
data: ["tools/research/tow/out/statics_table.csv", "tools/research/tow/out/compare.csv", "tools/research/tow/out/sens_cm.csv"]
applied_in: []
---
# TW-16: управляемость «Маятника» на тросе (продольный канал)

Исследование: [docs/research/tow/tow-control.md](../../../docs/research/tow/tow-control.md). Код игры не менялся.

## Состав

| Файл | Что |
|---|---|
| `statics.py` | Продольная статика (2D): крыло + пилот на стропе + трос (вперёд-вниз при ε>0, вверх при ε<0) с долей на пилота/киль, руки на штанге. Ньютон на numpy. `setup()` — калибровка по триму и выбор поправки Cm; `identify_cm` — ΔCm(α) модели из свободного полёта. Пишет `out/statics.json`, `statics_table.csv`, `sens_cm.csv` |
| `extra.py` | Статика при больших T лебёдки (до 1300 Н) → `out/statics_extra.json` |
| `compare.py` | Сверка PendulumModel со статикой по установившимся точкам → `out/compare.csv` |
| `tow_sweep.gd`, `tow_sweep.tscn` | Опыты на `PendulumModel` без `TowLine`: звено/сила троса, пилот держит тангаж киля; режимы `SWEEP=TRIM|T|EPS|FORCE|PFIX|TV|T2` |
| `run_model.sh` | Все прогоны Godot (≈6 мин) → `out/model_*.txt` |
| `out/model_*.txt` | Сырой вывод `tow_sweep` (строки `CSV,{json}`) |

## Воспроизведение

Окружение: Godot 4.7.2, Python 3 + numpy. Один раз в копии: `godot --headless --path . --import` (с профилем `XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD")`).

```bash
.dpcli/dpcli lock cpu tw16 -- tools/research/tow/run_model.sh   # из корня копии
cd tools/research/tow && python3 statics.py && python3 extra.py && python3 compare.py   # ≈ 4 мин
```

Выводные `CSV,` строки читаются `json.loads(line[4:])`. Окружение `tow_sweep`: `AT=pilot|hang|split`, `EPS` — угол троса **ниже** горизонта, °
(лебёдка: якорь на земле впереди; отрицательный — якорь выше, аэробуксир), `PFIX` — постоянный ввод тангажа, `VHOLD` — PI по скорости (**неустойчив**, не используется).

## Допущения (коротко; полно — в отчёте)

- Трос в «Маятнике» — звено XPBD к якорю на 300 м (EA = 3·10⁵ Н) ниже пилота на 300·sin ε и впереди на 300·cos ε; скорость якоря — П-регулятор по натяжению
  (`0,002 (м/с²)/Н`), слабого звена и срыва нет; ε постоянный (с высотой не растёт).
- Пилот держит тангаж киля (PI), пределы рук сняты (`free`): измеряется **потребное**, а не упор. Скорость получается, не задаётся.
- Статика: линейная аэродинамика (a=4,54, α₀=−6,0°, CD=0,03+0,042·CL² по поляре трима), НТ на уровне киля; недостающая Cm(α) модели берётся из её свободного полёта
  (`identify_cm`); чувствительность — `out/sens_cm.csv`.

## Источники и лицензии

BHPA Technical Manual (поправка 24), `BHPA_Tech_Manual_24.pdf` — в рабочей копии не коммитится, тексты — только выдержки с номером раздела.
Веб-источники (Wills Wing, Lookout Mountain, DHV, гл. «Источники» отчёта) — ссылки и короткие цитаты, данные не копировались.
Числа геометрии и аэродинамики — из `configs/wings/sport.json`, `configs/pendulum.json`, `scripts/flight/pendulum/*.gd` проекта.
Собственные таблицы `out/*` — данные расчёта, лицензия проекта.
