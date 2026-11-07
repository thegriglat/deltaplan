---
type: "research"
status: "active"
module: "sw-charges"
area: "air"
updated: "2026-11-08"
summary: "Прототип C (SWC-7): пуассоновы диполи ЛЧ и пары болтанки в 2D без рельефа на NumPy — код, команды, таблицы."
related: ["docs/research/sw_charges/proto-c.md", "docs/research/sw_charges/unified-scales.md"]
conclusion: "docs/research/sw_charges/proto-c.md"
data: "tools/research/sw_charges/proto_c/out/"
applied_in: ""
---
# Прототип C: пуассоновы диполи и пары (2D, без рельефа)

Вывод и числа — `docs/research/sw_charges/proto-c.md`. Данные малы (< 1 МБ), лежат в `out/`.

## Воспроизведение
Интерпретатор — `tools/research/cascade_2d/py` (numpy, scipy, matplotlib; в cascade_2d ничего не менялось). Из каталога `proto_c/`:

```
../../cascade_2d/py -I step1.py          # один термик, 0,2 с
../../cascade_2d/py -I step2.py          # пары + 11 сканов, ~9 мин
../../cascade_2d/py -I step3.py          # ансамбль термиков + 14 сканов, ~3,5 мин
../../cascade_2d/py -I build_results.py  # out/results.json (step1, step2, step3, criterion, timing)
../../cascade_2d/py -I figures.py        # out/fig_proto_c.png
```

Файлы: `common.py` (диполь Лэмба — Чаплыгина, профиль ветра), `step1.py`, `step2.py`, `step3.py`. Сиды зашиты (1, 2, 3).

## Что внутри
- ЛЧ-диполь: проверены div u = 0 (1e-8), ∫w dx = 0 по линии через центр, E = 2π U²a².
- Шаг 1: ОДУ термика (присоединённая масса k_m = 1, вовлечение α = 0,15, избыток θ′ разбавляется и теряется в стратификации).
- Шаг 2: ~9·10³ пар в периодической области 800 м, z 8…150 м; рождение λ = ε/E из баланса энергии; проверка на 4 высотах.
- Шаг 3: ≤ 10² термиков в периодической области 5 км + одномерное среднее поле θ̄(z), Ū(z); обратные потоки как дивергенция потока в клетках по следу хорды термика.

## Источники
Лэмб Г. Гидродинамика (диполь Чаплыгина — Лэмба); Gedeon 1988, Allen 2006, Lenschow & Stephens 1980 — через `docs/guide/air-model/thermals.md`; Kármán w-спектр MIL-HDBK-1797 — через `turbulence.md`. Данных извне нет, лицензии не требуются.
