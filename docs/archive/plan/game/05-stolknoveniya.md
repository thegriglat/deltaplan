# G05. Столкновения с проводами ЛЭП и препятствиями

**Цель:** задеть провод ЛЭП, дерево у посадки, забор или здание — это авария (итог полёта с понятной причиной), как в жизни (VR-10, VR-12).

**Контекст:** docs/guide/world-objects.md (`WorldObjects.wire_hit(a, b) -> bool`, `obstacle_hit(a, b) -> {kind, point}`), docs/guide/game.md, scripts/game/game.gd (Game.tick), scripts/game/flight_stats.gd (finish_reason), docs/guide/terrain.md (деревья: forest_at — есть ли API на столкновение с кроной).
**Папки-владения:** scripts/game/game.gd (только проверка столкновений в тике), scripts/game/collision_check.gd (новый, RefCounted), tests/game/test_collisions.gd, docs/guide/game.md. scripts/game/autopilot.gd не трогать (F01).

## Шаги
1. `CollisionCheck`: каждый шаг — отрезок движения крыла (концы консолей и пилот, не только центр) против `wire_hit` и `obstacle_hit`; лес — если в точке пилота `forest_at ≥ 0,5` и высота над землёй < высоты крон (из данных рельефа/деревьев) — касание кроны.
2. Столкновение → полёт завершён, finish_reason = "crash_wire" / "crash_obstacle" / "crash_trees", в итоге — причина по-русски; звук удара (FlightAudio.play_landing с оценкой crash).
3. Производительность: проверка только когда высота над землёй < 60 м (провода и препятствия ниже).

## Критерий приёмки
- Тесты: пролёт сквозь провод ЛЭП (координаты реального пролёта из data/osm) → crash_wire; пролёт в 20 м выше провода → полёт продолжается; посадка в дерево → crash_trees; нормальная посадка на поле → landed.
- Тесты game и stability зелёные; lint чисто; +≤0,1 мс CPU на шаг.

**Модель:** opus. **Размер:** S–M.
