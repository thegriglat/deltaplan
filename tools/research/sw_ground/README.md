---
type: "research"
status: "active"
module: "sw-ground"
area: "air"
updated: "2026-11-08"
summary: "Код и данные sw-ground: слой у земли панелей 3D, нить ротора на рельефе, время поля на окнах игры."
related: ["docs/plan/sw-ground.md", "docs/contracts/sw-ground.md", "tools/research/sw_charges_3d/README.md"]
---
# sw_ground — данные и команды

- Интерпретатор: `tools/research/sw_ground/py` (venv sw_charges_3d; пакеты `sw_charges_3d/*` — только импорт).
- Контракты: `docs/contracts/sw-ground.md` (SWG1–SWG4); тест — `py contract/check_contract.py <файлы>`, `--selftest`.
- Выходы: `out/points/` (SWG1), `out/<задача>/` (SWG2–SWG4). Разделы задач дописывают исполнители.

## Каталоги задач
- `ground/` SWG-1 (диагностика, «до»), `rotor/` SWG-2 (нить ротора), `timing/` SWG-3, SWG-6 (время окон), `wake/` SWG-4, `rotor_ground/` SWG-5, `sheet/` SWG-7, `zone/` SWG-8, `attached/` SWG-9, `vii/` SWG-10, `vii2/` SWG-11, `freeline/` SWG-12, `query/` — опрос поля.
- `summary/` SWG-13: свод и выбор (`py -m summary.select` → `out/summary/selection.json`, `tables.md`; `py -m summary.build_doc` → `docs/research/sw_ground.md`). Итог модуля — `docs/research/sw_ground.md`.
