---
type: "research"
status: "active"
module: "sw-charges-3d"
updated: "2026-11-08"
summary: "sw-charges-3d: панели-источники по рельефу и замкнутые вихревые нити в 3D против Askervein, Perdigão и Пикара — код, данные, команды."
related: ["docs/plan/sw-charges-3d.md", "docs/contracts/sw-charges-3d.md", "tools/research/sw_charges/README.md"]
conclusion: ""
data: "tools/research/sw_charges_3d/out/"
applied_in: ""
---
# sw_charges_3d — заряды и вихри в 3D

Интерпретатор — `./py` (venv `~/.cache/sw_charges_3d/venv`: numpy, scipy, matplotlib, h5py, cupy, pytest; PYTHONPATH —
этот каталог и `../sw_charges` для `panels2d`). Контракты — `docs/contracts/sw-charges-3d.md` (SWD1–SWD5),
контрактный тест — `./py contract/check_contract.py --selftest | files <пути> | api <пакет>`.

| Каталог | Что | Задача |
|---|---|---|
| `refs/` | эталоны 3D: Пикар (air3d, Б1 nom/adv1) и измерения → `out/refs/` (SWD1) | SWD-1 |
| `panels3d/` | треугольные панели-источники по рельефу, внутренний слой, отрыв (SWD2) | SWD-2 |
| `filaments3d/` | замкнутые вихревые нити (SWD3) | SWD-3 |
| `sim3d/` | связка панелей и нитей (SWD4) | SWD-4 |
| `compare/` | сравнение с эталонами → `out/compare/` (SWD5) | SWD-5 |
