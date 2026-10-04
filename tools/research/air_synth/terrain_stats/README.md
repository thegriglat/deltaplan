---
type: "reference"
status: "active"
module: "air-synth"
updated: "2026-10-04"
summary: "Код и команды воспроизведения статистик рельефа, разложения на формы и генерации (Fastscape, сумма форм) для air-synth"
related: ["docs/research/terrain_statistics.md"]
---
# air-synth: статистики рельефа, разложение на формы, генерация

Итог и выводы — `docs/research/terrain_statistics.md`. Здесь — воспроизводимый код.

Данные (только чтение): `data/terrain/{askarovo,ongudai,altai,aushkul}/{detail,far}.f32.br` (формат — `meta.json`; detail = Copernicus GLO-30,
25 м, 40×40 км; far = Terrarium/Mapzen, 100 м, 160×160 км). Лицензии — в `meta.json` каждого места и `ASSETS.md`.

Окружение (не коммитить `.venv`): `uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python numpy scipy matplotlib brotli numba fastscapelib`.
Все счёты — с `OMP_NUM_THREADS=1`.

| шаг | команда | выход (`out/`) | время |
|---|---|---|---|
| статистики 4 мест | `.venv/bin/python run_stats.py && .venv/bin/python tables.py` | `stats.json`, `stats_tables.md`, `peaks_*.npz` | ~3 мин |
| связи prominence, масштабирование перепада | `prom_relations.py`, `relief_scaling.py` | `prom_relations.json`, `relief_scaling.json` | секунды |
| разложение на формы | `decompose.py` (Pool(18); `dp job start`) | `decomp.json`, `decomp_*.npz` | ~25 мин на 18 ядрах (detail100 — по ~14 мин на задачу) |
| Fastscape (12+12 рельефов) | `run_fastscape.py` | `fastscape_metrics.json`, `fastscape_*.npz` | ~35 с на рельеф на ядро |
| сумма форм по статистикам | `gen_forms.py` (после decompose) | `forms_gen_*.npz/json` | секунды |
| сводная таблица, картинки, цена | `compare_tables.py`, `figures.py`, `taskset -c 7 .venv/bin/python timing.py` | `compare_tables.md`, `fig_*.png`, `timing.txt` | |

Файлы: `dem.py` (загрузка, огрубление), `stats.py` (дерево слияния/prominence, критические точки, уклоны, спектр, дренаж),
`forms.py` (формы плана §2 и жадное разложение), `fastscape_gen.py` (поле поднятия + SPL + диффузия + тепловая эрозия),
`compare.py` (набор метрик), `sweep1.py`/`sweep2.py` (грубая калибровка параметров Fastscape).
Крупных файлов нет (`out/` ~ 24 МБ, из них 14 МБ — поля Fastscape 100 м).
