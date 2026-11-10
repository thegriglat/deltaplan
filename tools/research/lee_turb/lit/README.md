---
type: "research"
status: "closed"
module: "lee-turb"
area: "air"
updated: "2026-11-10"
summary: "LT-1: литература и открытые данные о слое смешения за отрывом (уступ, холмы, Perdigão)"
related: ["docs/research/lee_turb.md"]
conclusion: ""
data: ""
applied_in: ""
---

# lee-turb: литература и открытые данные (LT-1)
- `lit_numbers.csv` — LTL v1 (72 строки); собирается `python3 -I build_lit.py` из таблицы в скрипте и `derived_exp.json`.
- `fetch_data.sh` — скачивает открытые таблицы экспериментов в `data/` (в git не кладутся); `extract_exp.py` считает из них `derived_exp.json`.
- Проверка: `python3 ../contract/check_contract.py lit_numbers.csv`. Выводы: `docs/research/lee_turb.md`.
- Данные: NASA Turbulence Modeling Resource (Delville, Driver–Seegmiller), ERCOFTAC KBwiki UFR 3-30 (Rapp–Manhart). Берутся числа, наборы не распространяются; лицензия KBwiki — на её странице.
- Тексты, прочитанные для A: Brown&Roshko 1974 (Caltech), NASA TM-86698, TM-85851, Menke 2019 (CC BY), Mann 2014.
- Надёжность: A — число из текста/таблицы источника, C — пересчёт A-чисел (формула в `note`); чисел по памяти нет.
