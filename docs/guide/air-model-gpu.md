---
type: "guide"
status: "active"
module: "air-model"
area: "air"
updated: "2026-10-15"
summary: "Решатель среднего поля воздуха на GPU: блоки, Пикар одного уровня, окна 100 и 50 м; вход, части, замеры RTX 4070 SUPER."
related: ["docs/guide/air-model.md", "docs/guide/air-model-gpu/blocks.md", "docs/guide/air-model-gpu/picard.md", "docs/guide/air-model-gpu/clipmap.md"]
---

# Модель воздуха на GPU

Решатель среднего поля воздуха (масштаб 1) на compute-шейдерах Godot (`RenderingDevice`). Что делает поле в игре — [air-model.md](air-model.md); здесь — как оно считается на GPU. Код — `scripts/atmosphere/air_model/`. Сетка — декартова с маской «под землёй» (решение AM-01, `tools/research/air3d/reference.md`); план — `docs/archive/plan/air-model.md` (AM-02…AM-04), решатель — `docs/archive/plan/wind-field.md` → «Решатель на GPU», WF-02/WF-03.

Слои по порядку снизу вверх:

1. **Блоки (AM-02)** — поэлементные ядра, редукции, прогонки по линиям, V-цикл давления и каркас задач порциями (`AirGpu`, `AirGpuJob`). Общий слой, не знает про ветер.
2. **Пикар (AM-03)** — одна область: `AirCase` (вход по столбцам), `AirPlace` (вход из места игры), ядра `air_picard.glsl`, задача `AirPicardJob`.
3. **Клипмапы (AM-04)** — окна 100 и 50 м вокруг пилота с границей от родителя: `AirWindowCase`, `AirWindowJob`, `AirClipmap`.
4. **Фазы** (классификатор и механизмы A/B/C/D/F/G/H, `AirPhaseJob` на том же каркасе `AirGpu`) — [air-model/phases.md](air-model/phases.md); загрузка и пересчёт в игре (`AirRuntime`) — [air-model/runtime.md](air-model/runtime.md).

## Части

| Часть | Что |
|---|---|
| [Строительные блоки (AM-02)](air-model-gpu/blocks.md) | файлы и ядра, раскладка буферов, прогонки, V-цикл, порции и API каркаса, точность и время блоков, переносимость (lavapipe, D3D12, GPU-AV) |
| [Пикар на GPU (AM-03)](air-model-gpu/picard.md) | вход и API, порядок программы, буферы, сверка с эталоном AM-01, замеры по ядрам и целиком, почему стена ≫ GPU |
| [Клипмапы (AM-04)](air-model-gpu/clipmap.md) | граница окна от родителя, сдвиг, сверка с эталоном, стык уровней, время, `AirRuntime` с окнами, границы |

## Главное
- Все буферы — `float32`; ядра GLSL 450 без расширений и subgroup-операций, группы ≤ 256 потоков, push-константы 48 байт — все блоки проходят на lavapipe (программный Vulkan), ядра собираются под D3D12 (проверка под wine с vkd3d-proton).
- Локальный `RenderingDevice` один на игру; главный поток не ждёт GPU: задачи идут порциями (≤ `chunk_ms`, ≤ 25 мс на экране загрузки), в очереди не больше одной порции — защита от сброса устройства Windows (TDR).
- Порядок сложения в редукциях задан только размером, поэтому два прогона побитно одинаковы (проверено тестами).
- Итерация Пикара области 400 м (98 × 98 × 52) — 3,3 мс на RTX 4070 SUPER (до А1; после А1 — 4,2 мс), 200 м — 11,2 мс (после — 14,2); решение пары (без нагрева + с нагревом) области 400 м — 0,73 с GPU, ≈ 2 с стены в окне тестов (до А1; после А1 итераций и времени больше). Подробно — [picard.md](air-model-gpu/picard.md).
- Ядро не собралось или нет GPU — расчёта нет, игра берёт аналитику ([air-model/field-cpu.md](air-model/field-cpu.md) → «Запасной путь»).

## Тесты и инструменты
`tools/gpu_tests.sh --filter=test_air_gpu` (блоки), `--filter=test_air_picard`, `--filter=test_air_window`; замеры — переменные `AIR_GPU_BENCH=1`, `AIR_PICARD_BENCH=1` (под `flock /tmp/heat_ca_gpu.lock`). Список тестов — `tests/atmosphere/test_air_*.gd`; эталоны — `tools/research/air3d/` (Python, float64) и `tests/atmosphere/fixtures/air_model/`. Проверка на слое валидации Vulkan, lavapipe и wine — [gpu-validation.md](gpu-validation.md).
