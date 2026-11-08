# Эталоны picard_rs cascade-2d (C0–C4, dx 400–50)

Дата: 2026-11-08 · Задача SWC-3 · Данные: `~/data/cascade_2d` (`$CASCADE2D_DATA`): `cases/`, `raw/`, `fields/<C>/` (F1 + F2).

## Команды (в копии, ветка `sw-charges/SWC-3`)

```
.dpcli/dpcli lock cpu swc3 -- cargo build --release --manifest-path rust/Cargo.toml -p picard_rs
tools/research/cascade_2d/py tools/research/cascade_2d/cases/build_cases.py --dx 400,200,100,50
tools/research/cascade_2d/py tools/research/cascade_2d/cases/run_refs.py solve --dx 400,200,100,50   # решатель под lock cpu cascade-ref, 1 поток
CASCADE2D_RUNS=~/data/cascade_2d/runs tools/research/cascade_2d/py tools/research/cascade_2d/cases/run_refs.py convert --dx 400,200,100,50
tools/research/cascade_2d/py tools/research/cascade_2d/contract/check_contract.py ~/data/cascade_2d/fields   # FAIL 0 (проверено 40)
tools/research/cascade_2d/py tools/research/cascade_2d/cases/run_refs.py table --dx 400,200,100,50
```

`table` пишет `convergence.{json,md}` в `tools/research/cascade_2d/cases/` (git). Чтобы не менять трек, вывод взят
из stdout, файлы восстановлены `git checkout`. Полная таблица сохранена в `~/data/cascade_2d/convergence_new.md`.
Прогоны — один поток (CPUQuota 100 % на слот замка). Всего 20 прогонов, все `status ok`.

## Таблица (run_refs table, dx 400–50)

| случай | dx, м | итераций | мс/итер | total, с | RSS, МБ | max rel_div | y_uniform |
|---|---|---|---|---|---|---|---|
| C0 | 400 | 20 | 4.66 | 0.2 | 6 | 8.01e-06 | 1.88e-05 |
| C0 | 200 | 40 | 16.81 | 1.0 | 11 | 3.13e-05 | 1.75e-05 |
| C0 | 100 | 80 | 58.75 | 6.0 | 33 | 2.81e-05 | 1.12e-05 |
| C0 | 50 | 160 | 251.66 | 46.0 | 118 | 2.42e-05 | 9.29e-06 |
| C1 | 400 | 40 | 4.92 | 0.3 | 6 | 4.26e-05 | 4.55e-05 |
| C1 | 200 | 140 | 15.88 | 2.6 | 11 | 5.91e-05 | 8.81e-06 |
| C1 | 100 | 310 | 62.56 | 21.0 | 34 | 3.62e-05 | 1.30e-05 |
| C1 | 50 | 800 | 253.55 | 212.2 | 128 | 2.41e-05 | 9.32e-06 |
| C2 | 400 | 60 | 4.69 | 0.4 | 6 | 1.23e-06 | 2.11e-06 |
| C2 | 200 | 120 | 16.18 | 2.3 | 12 | 2.42e-05 | 3.21e-06 |
| C2 | 100 | 340 | 62.76 | 23.1 | 33 | 1.47e-05 | 5.60e-06 |
| C2 | 50 | 860 | 249.19 | 224.0 | 118 | 9.44e-06 | 5.51e-06 |
| C3 | 400 | 30 | 5.64 | 0.3 | 6 | 2.60e-01 | 5.03e-01 |
| C3 | 200 | 30 | 19.35 | 0.9 | 11 | 7.63e-02 | 1.47e-01 |
| C3 | 100 | 130 | 70.82 | 10.6 | 33 | 1.35e-02 | 3.48e-02 |
| C3 | 50 | 260 | 279.20 | 79.0 | 128 | 9.25e-04 | 3.29e-03 |
| C4 | 400 | 50 | 4.59 | 0.3 | 6 | 1.94e-05 | 1.04e-05 |
| C4 | 200 | 150 | 16.22 | 2.8 | 11 | 5.48e-05 | 1.87e-05 |
| C4 | 100 | 390 | 58.95 | 24.7 | 33 | 2.85e-05 | 1.24e-05 |
| C4 | 50 | 880 | 262.53 | 240.6 | 123 | 2.30e-05 | 8.42e-06 |

U_ref на dx 50 (из `run.json`): C0 6,413; C1 6,496; C2 10,385; C3 1,217; C4 6,685 м/с.

## Сравнение с прежней таблицей (`HEAD:tools/research/cascade_2d/cases/convergence.md`)

- Итерации совпали во всех 20 случаях (сходимость детерминированна при 1 потоке).
- max rel_div и y_uniform совпали с прежними значениями до ~1 % (например, C1 d50 2.41e-05 / 2.42e-05; C3 d50 9.25e-04 / 9.30e-04).
- ms/iter и total_s отличаются в пределах шума (параллельная нагрузка соседей): например C0 d50 251,7 против 279,9 мс/итер.
- U_ref не сравнивается напрямую: в прежней таблице он взят с уровня dx 25 (P25), в этом прогоне — с dx 50.
  Уровень dx 25 не считался (задача ограничена 400–50), поэтому таблица P50 vs P25 (E_u, E_w, E_u_lee, СКО) пуста.

## Границы

- Файлы cascade-2d в git не менялись (`git status -- tools/research/cascade_2d rust` пуст).
- Сырьё и поля — вне git, в `~/data/cascade_2d`.
