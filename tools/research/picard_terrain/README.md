---
type: "research"
status: "active"
module: "picard-terrain"
updated: "2026-11-09"
summary: "picard-terrain: срезанные клетки и ограниченный 2-й порядок в picard_rs на той же сетке — случаи, прогоны, таблицы."
related: ["docs/plan/picard-terrain.md", "docs/contracts/picard-terrain.md", "rust/picard_rs/README.md", "tools/research/air3d/reference.md"]
conclusion: ""
data: "tools/research/picard_terrain/out/; крупное — $PICARD_TERRAIN_DATA (~/data/picard_terrain)"
applied_in: ""
---
# picard_terrain — мелкий рельеф в Пикаре

Контракты — `docs/contracts/picard-terrain.md` (PT1–PT5). Контрактный тест:
`python3 contract/check_contract.py selftest | cases <case.json>… | rows <rows.jsonl>…`;
побитно прежний путь `picard_rs` без флагов — `contract/check_default.sh` (`identical=4/4`).

| Путь | Что | Задача |
|---|---|---|
| `contract/` | контрактный тест, проверка побитности | координатор |
| `make_cases.py`, `sample.py` | случаи PT1, выборка PT5 | PT-1 |
| `out/<ID>/` | строки замеров PT4 (`rows.jsonl`), таблицы, команды воспроизведения | все |

Крупные данные (случаи R1, снимки R4, растры) — `$PICARD_TERRAIN_DATA` (по умолчанию `~/data/picard_terrain`).
