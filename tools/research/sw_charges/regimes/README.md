---
type: "research"
status: "active"
module: "sw-charges"
updated: "2026-11-08"
summary: "SWC-8: код, команды и время счёта таблиц режимов слоя Рипа A1 (F0 × M) и A2 (условия air-phase, R1)."
related: ["docs/research/sw_charges/stage1-regimes.md", "docs/contracts/sw-charges.md"]
conclusion: "см. docs/research/sw_charges/stage1-regimes.md"
data: "tools/research/sw_charges/out/regimes/"
applied_in: ""
---
# regimes: A1 и A2 (SWC-8)

Файлы: `theory.py` (M_c, M_s, бор, ветвь с прыжком, правило R1), `core.py` (случаи, прогон swpy, классификатор SW4),
`run_series.py` (серии), `build_tables.py` (→ `out/regimes/A1,A2.{json,csv}`), `analyse.py`, `make_doc_tables.py`.
Интерпретатор — `tools/research/sw_charges/py` (numpy). Сырые поля SW1–SW3 — `~/data/sw_charges/regimes/` (не в git; `SWC8_RAW`).

Воспроизведение (части параллельно, ≈ 25 мин на 6 ядрах; CPU суммарно 5094 с: A1 3844 с, A2 1250 с):
```
for p in a1a a1b a1c a1d a2a a2b; do .dpcli/dpcli job --lock cpu start swc8-$p 7200 tools/research/sw_charges/py tools/research/sw_charges/regimes/run_series.py $p; done
tools/research/sw_charges/py tools/research/sw_charges/regimes/build_tables.py
python3 tools/research/sw_charges/contract/check_contract.py tools/research/sw_charges/out/regimes
```
Допущения A2: α = 0,24, f = 1,1·10⁻⁴ с⁻¹, z0 = 0,1 м (U10 из U_sat); δ = 1500 м (`n_layer_m`). Лицензии: данных нет (синтетика), код проекта.
Строки JSON имеют добавочный ключ `diag` (читатель контракта его пропускает).
