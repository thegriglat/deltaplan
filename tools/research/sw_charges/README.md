---
type: "research"
status: "active"
module: "sw-charges"
updated: "2026-11-08"
summary: "sw-charges: опыты слоя мелкой воды (Рипа, reduced gravity) и зарядов на поверхности рельефа на Rust — данные, команды, таблицы."
related: ["docs/plan/sw-charges.md", "docs/contracts/sw-charges.md"]
conclusion: ""
data: "tools/research/sw_charges/out/"
applied_in: ""
---
# sw-charges: опыты

Форматы — `docs/contracts/sw-charges.md` (SW1 случай, SW2 поле, SW3 прогон). Проверка файлов:
`python3 tools/research/sw_charges/contract/check_contract.py <каталог>` (самопроверка — `--selftest`).

Разделы дописывают задачи модуля (SWC-n): крейт, воспроизведение, таблицы, где лежат крупные данные.

## Решатель swpy

Пакет `swpy/` — явный конечнообъёмный решатель модели Рипа (SW1) на NumPy: `case.py` (генератор SW1), `solver.py`
(схема, `run(case, out_dir) → (поле, запись)`), `io.py` (SW1–SW3), `cli.py` (`swc`). Внутри float64, в файлах float32.

Окружение: `tools/research/sw_charges/py` (обёртка, uv-venv в `${SWC_VENV:-$HOME/.cache/sw_charges/venv}`, `requirements.txt`: numpy, pytest).

Команды:
```
tools/research/sw_charges/py -m swpy case ideal --name N --shape ridge --H 50 --s 0.2 --dim 1 --nx 400 --dx 50 \
    --h0 500 --b0 0.1 --U0 2.1 --sponge-width 5000 --out DIR      # → DIR/N.json+.bin (SW1)
tools/research/sw_charges/py -m swpy run DIR/N.json --out OUT     # → OUT/N.field.json+.bin (SW2), OUT/N.run.json (SW3)
```
Код выхода `run`: 0 — steady/averaged/max_time, 3 — diverged. Проверка файлов: `contract/check_contract.py OUT`.
Дымовой прогон: `bash tools/research/sw_charges/swpy/smoke.sh`. Тесты: `tools/research/sw_charges/py -m pytest -q tools/research/sw_charges/swpy/tests`
(T1–T11 карточки SWC-4: покой, Риттер, Бернулли дозв./сверхзв., критичный гребень, переключение режима M_c, масса,
1D = 2D, трение+сила, нагрев, статусы SW3).

Схема: MUSCL (minmod по η, u, v, b) + SSP-RK2, HLL, well-balanced реконструкция Одюсса второго порядка; в клетках у
мокро/сухо, при h на грани ≤ 0 и в крайних клетках области — первый порядок. Трение неявно, сила `balance`, Кориолис —
поворот, нагрев и губка — расщеплением после переноса. dt = cfl/max(λx, λy) (+ страховка по сумме осей в 2D).
Границы модели: давление Рипа с переменным b не имеет точного покоя (покой точен только при b = const); вовлечения нет;
HLL размазывает контактный разрыв (v, b переносятся против потока массы — резкие); на фронте сухого дна схема первого порядка.

Замеры (CPU, NumPy, 1 поток, машина под нагрузкой других задач): T5 (1D, nx 800, dx 50, ridge a = 1000 м, M = 0,5, F0 = 0,5) — стационар
за ~13 400 с модельного времени, ≈ 8 100 шагов, ≈ 25 с; шаг 1D nx 800 ≈ 3 мс; шаг 2D 512×512 ≈ 0,5 с (SSP-RK2, две стадии).
Наблюдения: порог `steady_tol` (по умолчанию 5e-4 в генераторе и CLI) — 1e-4 у схемы второго порядка достижим не всегда (шум ограничителя на масштабе 2Δx, пол
невязки ≈ 1e-4 дозвук., ≈ 3e-4 сверхзвук.) — поэтому по умолчанию 5e-4 (как в тестах Бернулли/M_c). При M > M_c прыжок за гребнем стоит у ~1,8a
(сопряжённая глубина), а не дальше 2a; значения «на гребне» — среднее двух клеток по обе стороны x = 0.
