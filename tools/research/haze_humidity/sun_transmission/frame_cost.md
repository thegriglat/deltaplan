---
type: "research"
status: "active"
module: "haze-humidity"
area: "clouds"
updated: "2026-10-21"
summary: "HH-7: цена кадра света облаков через пропускание — GPU-замер не получен (earlyoom убивает godot), оценка по коду и CPU-цена таблицы."
related: ["docs/contracts/haze-humidity.md", "scripts/atmosphere/sun_transmission.gd", "scripts/atmosphere/cloud_common.gdshaderinc", "tools/bench/frame_profile.gd", "docs/plan/haze-humidity.md"]
conclusion: "Замера GPU нет: при MemAvailable < 10 % (tmpfs /tmp забит на 15 ГБ чужими tmp.*) earlyoom шлёт SIGTERM окну godot через 5–10 с (rc=143, 10 попыток подряд). Добавлено на луч облаков: один textureLod RGB на шаг освещения точки (cloud_sun_l(p.y)) и пересчёт направления на солнце один раз за вызов; таблица 64×64 RGBF (48 КБ), CPU-сборка 48 мс при старте и редко при смене дымки."
data: "tests/atmosphere/test_sun_transmission.gd (test_build_cost: 47,9 мс на 64×64, headless под нагрузкой); build/perf/after_eve.jsonl — неполный прогон (cloud_count 0), как цифра не годится"
applied_in: []
---

# HH-7 — цена кадра: свет облаков по пропусканию атмосферы

## Статус замера
GPU-замер «до/после» **не выполнен**. Все запуски `tools/bench/frame_profile.tscn` (окно, 1920×1080, `--fullscreen`,
`--gpu-profile`) завершаются SIGTERM (rc=143) через 5–10 с после старта, до первого кадра пробы. Причина — `earlyoom`
(`-m 10,5`, предпочитает `godot`): свободной памяти < 10 % (MemAvailable ≈ 1–2 ГБ из 31), т. к. `/tmp` (tmpfs) занят на
95 % (~15 ГБ, из них ~7 ГБ — каталоги `tmp.*` с выводом сборки сайта от других задач). Исполнитель HH-7 чистить чужой
`/tmp` не стал. Предыдущая попытка (10 повторов с паузой) — то же. Повторить, когда память освободится.

## Что добавлено на кадр (по коду)
- Таблица `T(el, h)` — `ImageTexture` RGBF 64×64 (48 КБ), строится на CPU при старте и при смене extinction/верха дымки
  более 5 %; в кадре нет работы CPU, кроме передачи шести параметров в материал/эффект.
- Шейдер (оба хоста — `cloud_volume.gdshader`, compute `cloud_raymarch_cs`): `cloud_sun_l(p.y)` — **один `textureLod`
  (RGB, линейный фильтр, 64×64) на шаг луча, где считается освещение**, и умножение на `base / sun_tref`; направление на
  солнце считается один раз за вызов `cloud_march_part`. Таблица 48 КБ целиком в L1/L2, разброс адресов по `y` мал.
- Затраты по порядку величины: на шаге освещения уже идёт `light_steps` (3–6) выборок плотности из 3D-текстур плюс шум;
  одна выборка маленькой 2D-текстуры добавляет заметно меньше 10 % к стоимости шага (оценка, не замер).

## CPU-цена таблицы
`test_build_cost`: 64×64 за **47,9 мс** (headless, под нагрузкой машины) — выше ориентира 10–30 мс из карточки; один раз
при старте и при смене дымки > 5 %, не в кадре. Если мешает — уменьшить `n_el`/`n_h` в
`configs/atmosphere.json → clouds.sun_transmission` или считать в потоке.

## Воспроизведение
```
DISPLAY=:0 XDG_DATA_HOME=<профиль с собранным ongudai> godot --path . --audio-driver Dummy --disable-vsync --fullscreen \
  --resolution 1920x1080 --gpu-profile res://tools/bench/frame_profile.tscn -- --location=ongudai --tag=<метка> \
  --game-args=--hour=19.5,--temp=30 --marks=30:chase --sample=2 --exps=base,noclouds,base2 --out=build/perf/<метка>.jsonl
```
Повторить для `--hour=14` и для ревизии `feature/haze-humidity` (до); сравнить `gpu_ms`/`gpu_ms_1pct` опыта `base` и разность
с `noclouds` (проход облаков). Профиль Godot должен содержать собранное место (иначе «место не собрано: network»).
