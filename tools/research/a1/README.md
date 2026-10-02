---
type: "research"
status: "closed"
module: ""
updated: "2026-10-03"
summary: "А1.1 — пробы для плана структурных правок решателя воздуха — Воспроизведение (из этого каталога; venv с CuPy и brotli — tools/research/morris/README.md; здесь использован /home/greg/deltaplan-wf-morris/tools/research/tune/.venv): bash PY=/home/greg/deltaplan-wf-morris/tools/research/tune…"
related: []
conclusion: ""
data: "tools/research/a1/"
applied_in: ""
---
# А1.1 — пробы для плана структурных правок решателя воздуха

План — `docs/archive/plan/air-model-a1.md`. Решатель (`tools/research/air3d/air.py`) не правится: правки
прототипированы подклассами в `probe.py` (`PrtAir` — Pr_t; `SplitAir` — θ′ = θ′_a + θ′_d, схема A′;
`HAir` — h слоя при `closure = const`).

| Файл | Что |
|---|---|
| `probe.py` | подклассы и пробы: `saddle` (2), `const` (3), `heat` (heated_slope до/после), `prt` (1), `ongudai` (Онгудай 12:00 до/после) |
| `askervein_chi2.py` | χ² Askervein (47 наблюдаемых перекалибровки) прямо по строкам runs-файла `recal` — рецепт приёмки (4) |
| `run_probes.sh` | все пробы подряд под замком GPU через `tools/job.sh` |
| `out/*.json`, `out/*.log` | числа проб (30.09.2026, air.py на 28ab3de, RTX 4070 SUPER, float32) |

Воспроизведение (из этого каталога; venv с CuPy и brotli — `tools/research/morris/README.md`; здесь
использован `/home/greg/deltaplan-wf-morris/tools/research/tune/.venv`):
```bash
PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python
flock /tmp/heat_ca_gpu.lock $PY probe.py const     # ~1 с GPU
flock /tmp/heat_ca_gpu.lock $PY probe.py heat      # ~1 с
flock /tmp/heat_ca_gpu.lock $PY probe.py saddle    # ~20 с (6 решений 128×128×62)
flock /tmp/heat_ca_gpu.lock $PY probe.py prt       # ~30 с (6 цепочек 400 → 100 → 50 м)
flock /tmp/heat_ca_gpu.lock $PY probe.py ongudai   # ~30 с
# или всё фоном: PROBES="saddle prt ongudai" /home/greg/deltaplan/tools/job.sh start a1-probes 1800 sh run_probes.sh
$PY askervein_chi2.py ../recal/out/runs_check25.jsonl   # χ² 68,06 (опорное для приёмки (4))
```

Главные числа: седловина без нагрева ×(седло/склон) на 20 м при τ 1800 / 7200 / 21600 с — сейчас
1,71 / 1,90 / 1,99, с разделением 2,051 / 2,051 / 2,055; `closure=const` + `cbl` сейчас —
`AttributeError: h_bl`, с h как в hb — 51 итерация; Pr_t 1 → 0,85 меняет подъём у старта на ≤ 0,02 м/с
(cbl); разделение θ′ в штиль Онгудай 12:00 снижает подъём у старта в окне 50 м 0,52 → 0,44 м/с, при 3 м/с
без изменений.

## После А1.2 (правки в air.py)
Подклассы работают только на air.py до правок (30bb2b9) — числа «до» в `out/<проба>.json`. На нынешнем
air.py — режим `after` (всё на `A.Air`, Pr_t = 0,85, θ′_d): `probe.py <проба> after` → `out/<проба>_after.json`
(`prt_step1_after.json` — только Pr_t, после шага 1; `const_step3_after.json` — после шага 3). Askervein
check25 после А1 — `../recal/out/runs_check25_a1.jsonl` (опорный до — `runs_check25.jsonl`).

Данные: рельеф Онгудая — `data/terrain/` (ASSETS.md); Askervein — Zenodo 4095052 (CC BY 4.0), только
через файлы `recal/out`.
