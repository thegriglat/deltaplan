---
type: "research"
status: "active"
module: "pilot-feedback-trim"
area: "flight"
updated: "2026-11-02"
summary: "PFT-4: сценарий разбега и отрыва с рядом 1/120 с, подмены α_neutral и момента передачи рук, разбор; воспроизведение."
related: ["docs/research/pilot-feedback-trim/liftoff.md"]
---
# PFT-4: переход «ноги → подвеска» после отрыва

Записка — `docs/research/pilot-feedback-trim/liftoff.md`; вердикт по PFT-К2 — `tools/research/pilot-feedback-trim/out/PFT-4_verdict.json`.
Код игры, конфиги, тесты не менялись; база — сценарий PFT-1 `longitudinal/trim_batch.gd` (режим `launch`), расширен рядом 1/120 с и подменами.

## Что внутри
- `liftoff_batch.gd` / `.tscn` — разбег по склону (`--slope=12,17`), отрыв, ряд −2…+`post` с от отрыва (поля: t, V, θ, α, γ, q, uprights, высота ступней, rel_xyz, shift_y,
  сила рук, момент паруса, натяжение стропы, vz, running, contact, stall). Подмены через публичные поля модели: `--alpha_neutral=<°|trim>`, `--bar_after=<с>`, `--upright_clear=<м>`.
  `--mode=air --v0=<км/ч>` — эталон: старт в воздухе с отклонением скорости, штанга в нейтрали.
- `run.sh` — запуск (профиль `XDG_DATA_HOME` по имени копии); `run_all.sh` — база, подмены, эталон; `run_scan.sh` — сетки α_neutral и bar_after (sport, ww_t2c).
- `analyze.py` (таблицы по прогонам, `out/summary.json`), `analyze_scan.py` (сетки + оценка Ланчестера, `out/scan_summary.json`).
- `out/` — сырьё `*.json.gz` (≈ 12 МБ), `base_table.txt`, `scan_table.txt`, `base_lanchester.txt`, `summary.json`, `scan_summary.json`.

## Воспроизведение (из корня копии; первый запуск — `godot --headless --path . --import`)
```
L=tools/research/pilot-feedback-trim/liftoff
.dpcli/dpcli job start pft4b 3000 .dpcli/dpcli lock cpu pft4 -- $L/run_all.sh
.dpcli/dpcli job start pft4c 3000 .dpcli/dpcli lock cpu pft4 -- $L/run_scan.sh
cd $L && gzip -9 out/*.json && python3 analyze.py out && python3 analyze_scan.py out   # analyze читает и .json.gz
```
Трим для разбора — `../longitudinal/out/steady_game.json.gz` (PFT-1). Без расширения `addons/dp_air` (ошибки загрузки в логе безвредны: штиль).

## Источники и лицензии
Данные — только собственные расчёты модели. Литература: Жеглов, Рыбкин, Мацепуро, «Учись летать на дельтаплане» (1983), с. 108–110, через `docs/research/zheglov-1983/takeoff-landing.md`;
BHPA Technical Manual, поправка 24 (2025) — выдержки без копирования (файл в корне основной копии, не коммитится); фугоида Ланчестера — общеизвестная оценка (ζ ≈ 1/(√2·L/D), ΔV_амп = √(ΔV² + (V·Δγ/√2)²)).
