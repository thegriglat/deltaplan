# W01. Провода, опоры и заборы OSM — без просадки FPS

**Цель:** в Онгудае у земли 1%-low ≥ 60 FPS на целевом железе (RTX-класс), как на остальных локациях.

**Контекст:** docs/guide/game.md → «Замеры» (Онгудай: среднее 69–88, 1%-low 31–43; wires 11 012, supports 3 767, wire_tiles 775, osm_fence_spans 2 230), docs/guide/world-objects.md, scripts/world_objects/ (провода, опоры, заборы), configs/world_objects.json, tools/bench/frame_bench.sh.
**Папки-владения:** scripts/world_objects/, scenes/world_objects/, configs/world_objects.json, tests/world_objects/.

## Шаги
1. Профилировать Онгудай у земли (draw calls, объекты): tools/bench/probe (medium).
2. Опоры и столбы заборов — MultiMesh по тайлам; провода — один меш на тайл (цепные линии запечь в ArrayMesh), visibility_range с запасом; заборы дальше N м — не рисовать.
3. Проверить, что визуально ничего не пропало (скриншоты «wires»/«village» до и после).

## Критерий приёмки
- tools/bench/frame_bench.sh (medium, fullscreen 1920×1080, под timeout): Онгудай — среднее ≥ 120, 1%-low ≥ 60 во всех отметках; остальные локации не хуже, чем до.
- Скриншоты до/после с провода и забора вблизи — идентичны по составу объектов.
- Тесты world_objects зелёные, lint чисто.

**Модель:** opus. **Размер:** S–M.
