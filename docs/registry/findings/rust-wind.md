---
type: "registry"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "Выводы rust-wind: ветер и погода в крейте dp-air, цена шага от размера места, удалённые запечённые поля и режим off, чистота крейта."
related: ["docs/registry/findings.md", "docs/research/rust-wind-stage3/final-run.md"]
---
# Выводы: rust-wind

- Ветер и погода перенесены в Rust (`rust/dp-air`, мост `dp-gd`): контракт W1–W12, слагаемые болтанки и порывов совпали с Godot побитно (шум и спектр), sigma[turb] ongudai: 7 случаев, 1244 точки, вне допуска 0 (RW-8) — [rw8-rw9.md](/docs/research/rust-wind-stage3/rw8-rw9.md#rw-8-болтанка-поля-и-шум-порывов); погода E1–E5, E7–E10: расхождений 0 (RW-14c) — [rw14-weather.md](/docs/research/rust-wind-stage3/rw14-weather.md#эталоны).
- Старый GD/GLSL-код ветра удалён (RW-13); сверки с эталонами, которых нет в cargo, перечислены поимённо — [rw13-cleanup.md](/docs/research/rust-wind-stage3/rw13-cleanup.md#удалённые-тесты-и-проверки-которых-нет-в-cargo).
- Упрощённый режим «ветер без поля» убран; поле считается всегда, и пилот не видел «Рассчитываем ветер» из-за настройки `off` и из-за отсутствия `quantum_h` в условиях игры (крейт отвергал их молча: READY за 0,0 с, ветер 0) — [no-off-mode.md](/docs/research/rust-wind-stage3/no-off-mode.md#почему-пилот-не-увидел-рассчитываем-ветер), [pilot-air-stage.md](/docs/research/rust-wind-stage3/pilot-air-stage.md#причина).
- Запечённые поля островов (8 файлов, ≈45 МБ) бесполезны: крейт читает все 8, принимает по `data_hash`, но отвергает по `model_hash` (50e249bed5ee6b3c в файлах, 7da6a196ca606f39 в коде); удалены, кеш полей оставлен — [baked-islands.md](/docs/research/rust-wind-stage3/baked-islands.md#замер-факт), [no-baked.md](/docs/research/rust-wind-stage3/no-baked.md#удалено).
- Цена шага `dp-air` от размера места не зависит (отношение 3041²/1041² 0,974, диапазон 0,65–1,0; 41,2 мс/с на 3041²); Q3 (1,5 с на игровую секунду) в крейте не воспроизведена — [rw15-step-cost.md](/docs/research/rust-wind-stage3/rw15-step-cost.md#замер).
- В игре главный поток Godot от размера не зависит (21,1 мс/с при 1041² против 21,5 при 3041², недетерм.), растёт фоновый CPU крейта 219 → 373 мс/с (≈1,7x, оценка снизу), всплески `advance_to` 100–450 мс/с; Q3 не доказана — [rw15b-game-profile.md](/docs/research/rust-wind-stage3/rw15b-game-profile.md#что-растёт-с-размером).
- Чистота `dp-air` от Godot и игровых имён: 458 нарушений (код 132, комментарии 332) → 0, `unsafe` убран (RW-16a/b) — [rw16-purity.md](/docs/research/rust-wind-stage3/rw16-purity.md#проверка).
- Крейты arc-swap, glam, rand_pcg, jiff не нужны: снимок поля раз на пакет 37 нс при 3300 нс на 18 точек, rand_pcg 1,87 против 2,05 нс своего ГСЧ, день года 5,3 нс (jiff 2,1) — [rw17-crates.md](/docs/research/rust-wind-stage3/rw17-crates.md#итог).
- Тесты при поле «всегда»: контрактные 27/27 за 65–78 с (было 12 мин 23 с); найдены дефекты крейта (граница): `start_at(t)` не равен прогону с 0 (t=20 с термиков 41 против 52), `cirrus_cover` не влияет в фасаде — [tests-field-always.md](/docs/research/rust-wind-stage3/tests-field-always.md#дефекты-крейта-не-чинились).
- Итоговый прогон этапа 3 (граница): T1 release 13 из 17, `advance_to` на Онгудае 1,71 мс против порога 0,5 мс (бенч без места 3,5 нс — условия разные), 108 новых падений GDScript против main (причина не разобрана), T9 не выполнен — [final-run.md](/docs/research/rust-wind-stage3/final-run.md#падения-cargo-workspace-no-fail-fast).
- `xc_run --synthetic` висел из-за шага места 250 м (крейт принимает 25 м): исправлено, 5 км за 1 мин (1407–1422 с полёта, 2 термика, 107 кругов), 15 и 30 км не завершились — [t9-xc.md](/docs/research/rust-wind-stage3/t9-xc.md#прогоны---synthetic---seed1-release-расширение).
- `cores()` пуст у динамических термиков, когда стенд строит место с шагом 100 м (поле принимает только 25 м); на игровом месте ≈100 ядер в 8 км за 0…3600 с — [dynamic-thermals.md](/docs/research/rust-wind-stage3/dynamic-thermals.md#причина-воспроизведено-в-cargo).
