# Эталоны полей Пикара, перепечатанные для крейта (rust-wind, W8 v2)

Запечённые поля формата `dp-air-baked` (как `data/locations/*/air/*`; читает `parse_baked`,
`rust/dp-air/src/field/baked.rs`), которые нельзя брать из игры как есть. Опорная ревизия печати —
**`c591b1026`** (опорная ревизия rust-wind). Файлы игры `data/locations/**` не затронуты.

## training_island/landing_hill.{json,bin}
Зачем: поле игры (GPU) для `landing_hill` считано с насыщением веса F в f32 (RW-U1,
`docs/research/rust-wind-t1-audit-landing-hill.md`) — как эталон оно неверно. Здесь фазы посчитаны
CPU-путём `AirPhaseCpu` (`air_phase_cpu.gd`, «тот же код, что ядра `air_phase.glsl`, построчно, в float64»);
Пикар (область 400 м, окна 100 и 50 м) — тот же GPU-путь игры, что и в поле игры.

Что отличается от печати игры (`tools/research/rust_wind_t1_ref/ref_c591b1026.patch`, на копию ревизии, саму ревизию не менять):
- `bake_air.gd --cpu_phases`: `AirRuntime.phase_factory` отдаёт `cpu_phase_job.gd` (`AirPhaseCpu.run`, f64) вместо `AirPhaseJob` на GPU;
  `air_model.timeout_s` = 7200 с (фазы на GDScript — ~100 с);
- в `meta` каждого уровня записан `solver: {heat: {stop, iters, div_rms}, mech: {stop, iters, div_rms}}` — итог
  `AirPicardJob.results` (порядок «без нагрева, с нагревом»; область — последний проход загрузки, окна — последняя запись
  `AirClipmap.history` с тем же dx). `stop`: `ok` -> `converged`, `max` -> `max_iters`, `diverged` -> `diverged`;
- `bake_air.gd`: `terrain.location_id = ""` — иначе `Terrain._ready` грузит место по умолчанию (altai, сеть) и в гонке
  подменяет центр места (в key попадает чужой `center`).
Ключ `key` (центр, `data_hash`, погода, старт, окна) тот же, что у поля игры; `model_hash` другой
(`c28c394c28da8707` против `50e249bed5ee6b3c` — хеш считается по исходникам модели, на ревизии с крючками и после неё).

Статус решателя (из файла): область dx400 — итераций 0 (колонны заморожены целиком: доля заморозки 1,00, фазы F 0,99 и H 0,01),
`div_rms` ~4e-10 (heat) и ~3e-10 (mech); окно dx100 — heat 180 итераций, mech 30; окно dx50 — heat 240, mech 40; все `converged`,
`div_rms` ≤ 7e-10.

## Воспроизведение
```
tools/research/rust_wind_t1_ref/run.sh landing_hill
```
Нужны Godot 4.7.2 с окном (`DISPLAY`, GPU Пикара), ~1 ГБ диска под временную копию ревизии (`git worktree add --detach
~/worktrees/deltaplan/rw6u-ref c591b1026`; после — `git worktree remove --force`). Расчёт ~3,5 мин (фазы ~100 с, Пикар области
и окон ~100 с). Повтор даёт те же числа статуса побитно (две печати подряд).
Сравнение с крейтом по классам клеток W8 v2 — `tools/research/rust_wind_t1_ref/compare.py` (README рядом).
