---
type: "research"
status: "active"
module: "cascade-2d"
updated: "2026-11-04"
summary: "cascade-2d: проверка каскада по уровням на квази-2D разрезе против Пикара 25 м; заготовка README (итог пишет CSD-4)"
---
# cascade-2d

## Цель
Проверить, имеет ли смысл каскад по уровням (400→25 м) на квази-2D разрезе по сравнению с
эталоном Пикара 25 м. План и критерии — `docs/plan/cascade-2d.md`, форматы — `docs/contracts/cascade-2d.md`.

## Каталоги
- `contract/` — `cascade2d_io.py` (чтение/запись F1, F2, `div2d`, `rel_div`), `check_contract.py` (проверка F1/F2/M1), `test_contract.py`.
- `py` — обёртка Python с venv; `requirements.txt` — зависимости.
- `out/runs/<C>/` — копии записей прогонов F2 (в git); `out/metrics/<C>.{json,csv}` — метрики M1.

## Данные
`$CASCADE2D_DATA` (по умолчанию `~/data/cascade_2d`): `cases/` (случаи R1), `fields/<C>/` (F1 и F2).

## Воспроизведение
```
tools/research/cascade_2d/py tools/research/cascade_2d/contract/test_contract.py
tools/research/cascade_2d/py tools/research/cascade_2d/contract/check_contract.py --selftest
tools/research/cascade_2d/py tools/research/cascade_2d/contract/check_contract.py $CASCADE2D_DATA/fields
```
venv создаётся при первом запуске (`CASCADE2D_VENV` переопределяет путь).

## Итог
(пусто — пишет CSD-4)
