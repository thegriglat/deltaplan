---
type: "research"
status: "closed"
module: "air-model"
updated: "2026-10-03"
summary: "AM-09: калибровка масштаба 1 и порогов масштаба 3 по Askervein схемой Professor (полиномы по прогонам, χ², eigentunes)."
related: ["docs/research/air-model-tune.md", "docs/research/air-model-sensitivity.md"]
conclusion: "Итог волны 1: ТКЭ Askervein после согласования масштаба 3 χ² 141 → 33; вывод «данные тянут λ/h вверх» оказался артефактом ручного α = 0,17 (см. реестр выводов)."
data: "tools/research/tune/out/"
applied_in: "параметры AirCase (λ/h = 0,25, пороги lee.field_*), configs/atmosphere.json"
---

# Калибровка AM-09 (Professor)

**Вопрос.** Какие значения λ/h, α, z0 и порогов отрыва лучше всего согласуют эталон масштаба 1 и масштаб 3 с данными Askervein.

**Что лежит.**
- `askervein_runs.py`, `askervein_fields.py` — прогоны эталона `air.py` на сетке параметров → наблюдаемые (FSR вдоль линий A, AA, B; Taylor & Teunissen 1985).
- `professor.py`, `fit_s1.py`, `fit_s3.py` — схема Professor, подгонка масштаба 1 и порогов отрыва масштаба 3 (по ТКЭ).
- `run_am09b.sh`, `run_rest.sh`, `am09b_summary.py` — пачки AM-09б (λ/h 0,25); `cost_check.py`, `pilot_check.py`, `repro.py` — цена и повтор.
- `out/` — планы эксперимента, `fit_*.json`, рисунки, `am09b/`.

**Данные.** `tools/research/tune/out/`; текст — `docs/research/air-model-tune.md`; выводы — `docs/registry/findings.md` (раздел air-model).
