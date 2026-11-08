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
