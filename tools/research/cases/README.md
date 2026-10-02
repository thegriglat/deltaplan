---
type: "research"
status: "closed"
module: "air-model"
updated: "2026-10-03"
summary: "Случаи калибровки модели воздуха (Askervein, Perdigão, Б1): общие правила постановки и схема решателя, контракт C10."
related: ["docs/contracts/air-model.md"]
conclusion: "Perdigão: модель не воспроизводит отрыв за двойной грядой (L/D 0,20–0,40 против 0,50 в данных) — граница модели; см. реестр выводов."
data: "tools/research/cases/ и tools/research/data/"
applied_in: "совместная калибровка (tools/research/tune), контракт C10"
---

# Случаи калибровки

**Вопрос.** Как одинаково ставить случаи (Askervein, Perdigão, …), чтобы параметры калибровались на одной схеме.

**Что лежит.**
- `rules.py` — общие правила постановки (сетка и область в единицах высоты рельефа H, профиль притока), контракт C10 v3.
- `scheme.py` — общая схема решателя (C10 v2); `check_c10.py` — контрактный тест формы случая.
- `askervein.py`, `perdigao.py` — модули случаев; `b1/` — этап Б1 (README внутри), `perdigao/` — данные и таблицы случая (README внутри).

**Данные.** Измерения — `tools/research/data/` (Askervein, Perdigão); результаты — `tools/research/tune/out/` и `docs/research/air-model-tune.md`.
