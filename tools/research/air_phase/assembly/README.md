---
type: "research"
status: "active"
module: "air-phase"
updated: "2026-10-06"
summary: "Сборка поля по фазам (AP-17, P8 v1): классификатор фаз и механизмы A, D, LEE, E/F, H из рельефа и условий без поля решателя; используется как тёплый старт Пикара и механизмы в прототипе «фазы + Пикар» (AP-18, P9)."
related: []
conclusion: ""
data: "tools/research/air_phase/assembly/"
applied_in: ""
---
# Сборка поля по фазам — прототип (AP-17, контракт P8 v1)

Поле масштаба 1 строится из рельефа и условий SY-12 без сети: классификатор фаз по клеткам, механизмы A (линейная
теория JH75/Sm80 через DCT), D (разделяющая линия тока H_c + слои Лапласа), LEE (огибающая 12° + пузырь),
E/F (θ′ — баланс столба, анабатика — простая форма, σ_w — подобие), H (среднее = D, разброс — статистика), фон —
столб того же K-замыкания с разгоном и сопротивлением формы; один шаг проекции ∇·u = 0 (MAC, координаты ζ = z − h).
Физика и источники — docstring в `mechanisms.py`, классификатор — `assemble.py`. Итог — `../analysis/AP-17/section.md`.

## Воспроизведение
```
PY=/home/greg/deltaplan-air-synth/tools/research/air_nn_pilot/.venv/bin/python
$PY -m pytest -q tools/research/air_phase/tests/test_assembly.py
bash tools/research/air_phase/assembly/run_all.sh      # ≈ 13 мин на 16 процессах CPU, затем разбор
```
## Данные (только чтение, лицензии — как у SY-12: рельеф hg_v2 из открытых DEM по ASSETS.md, условия и поля — наш счёт)
- поля решателя S5 v4: `~/air_synth_data/solve/hg_v2__hgw24__s0-939a467/`; условия S2 v4: `~/air_synth_data/conditions/hg_v2_hgw24/`.
## Выход (локально, не в git; ~1,2 ГБ на вариант)
- `$AIR_SYNTH_DATA/phase/assembly_v1/part-*.h5` — P8 (cases, fields/f f2, fields/m f2 — дополнительно, weights u1 ×255),
  `metrics-*.jsonl` — метрики слоёв P6 сборки и Пикара, ошибки по фазам и в швах, время; `oracle_profile.jsonl` —
  диагностика «оракул профиля».
- `$AIR_SYNTH_DATA/phase/assembly_v1_noana/` — вариант без анабатики.
