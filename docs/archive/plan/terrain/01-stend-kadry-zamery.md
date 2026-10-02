# T01. Стенд: фиксированные кадры, эталонные фото, замер GPU

**Цель:** один скрипт снимает одни и те же кадры рельефа и меряет GPU, чтобы все следующие карточки сравнивались с базой и с 3 реальными фото.

**Контекст:** docs/guide/terrain.md («Превью и замеры»), scripts/terrain/terrain_preview.gd, configs/locations/ongudai.json,
docs/guide/world-objects.md («Просеки»), docs/research/visual_cues.md.
**Владения:** `tools/terrain/shots.json`, `tools/terrain/shots.sh`, `tools/terrain/compare_ref.py` (новые),
`scripts/terrain/terrain_preview.gd`, `data/terrain/reference/` (новая, с `.gdignore`).
**Не трогать:** terrain.gd, configs/world.json, docs/guide/terrain.md (описание стенда — в шапке `shots.sh`; абзац для docs — в отчёт).

## Шаги
1. `shots.json` — кадры (координаты подобрать и зафиксировать): Онгудай S1 старт `kayancha_south` 2 м AGL;
   S2 посадка `ongudai_fields` 30 м; S3 опушка лес/луг 300 м, pitch −35°; S4 1000 м вдоль долины Урсула (река в кадре);
   S5 2000 м, pitch −8°, на дальние хребты (лес с высоты + дымка + хребты ≥ 20 км); A1 Аскарово 500 м; U1 Аушкуль 500 м на озеро.
   Для каждого кадра — прямоугольники «лес», «луг», полосы «близко/средне/далеко» и линия профиля через опушку (S3).
2. `terrain_preview.gd`: `--clearings` (маска `WorldClearings.build_for(id)` → `set_clearings`), `--bench-static=N`
   (N кадров неподвижно, печать JSON: gpu_ms среднее/95 %, отдельно прогон `--no-trees --no-grass --no-haze` = «рельеф»).
3. `shots.sh [выход]` — все кадры 1920×1080 + бенч в `<выход>/bench.json`; время прогона ≤ 3 мин.
4. 3 реальных фото (Wikimedia Commons, CC0/CC-BY/CC-BY-SA): (a) горы Алтая/Урала с лесом пятнами с 1–2 км;
   (b) опушка и луг с 200–400 м (дрон/параплан); (c) долина с дымкой и хребтами за 20+ км. `sources.json`:
   url, автор, лицензия, примерная высота, прямоугольники «лес/луг/полосы».
5. `compare_ref.py`: для кадра и фото — средняя яркость и RMS-контраст по областям, отношение лес/луг,
   контраст далеко/близко, профиль яркости по линии (ширина перехода 10→90 %, провал у кромки); монтаж «кадр | фото».
6. Снять базу: `data/terrain/reference/baseline/` (PNG не коммитить, только `bench.json` и `metrics.json`).

## Критерий приёмки
- `tools/terrain/shots.sh /tmp/base` дважды подряд: метрики совпадают ≤ 1 %, gpu_ms ≤ 5 %.
- `metrics.json` содержит все 7 кадров и 3 фото; монтажи S3|b, S5|a, S5|c открываются.
- `godot --headless … -s addons/gut/gut_cmdln.gd -gdir=res://tests/terrain` зелёный.

**Зависимости:** нет (волна 0). **Модель:** sonnet. **Размер:** S.
