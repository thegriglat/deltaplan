---
type: "guide"
status: "active"
module: "world"
area: "world"
updated: "2026-10-15"
summary: "Каркас пасхалок мира: планировщик, как добавить, запреты, место (EggPlace). На сайт не публикуется."
related: ["docs/guide/world-objects.md"]
---
# Пасхалки

Вход — [world-objects.md](../world-objects.md). Контракт — `docs/contracts/easter-eggs.md`. Файл на сайт не выкладывается.

## Пасхалки (`easter_eggs.gd`, `EasterEggs`; контракт — `docs/contracts/easter-eggs.md`)

Редкие чисто визуальные детали мира и неба (лайнер, шары, …). Планировщик — узел `Game/EasterEggs`:
ход кадром (`_process`), только в полёте, время — `Game.world_time()`; расписание зависит от ключа
мира, `id` и окна времени (одно и то же при любом шаге кадра и после прыжка времени). Физике и сети не мешает.

Как добавить пасхалку:
1. Скрипт `scripts/world_objects/easter_eggs/<id>.gd`: `extends EasterEgg`; `static can_appear(ctx, cfg)`,
   `begin(ctx, cfg, rng, t0)` (все случайные параметры — только из `rng`), `update(ctx) -> bool`
   (поставить себя в момент `ctx.t`, `false` — кончилась). Ассеты — `assets/easter_eggs/<id>/`.
2. Блок `eggs.<id>` в `configs/easter_eggs.json`: `enabled`, `script`, `mode` (`interval` | `per_flight` |
   `condition`) + поля режима, `lifetime_s` (0 — постоянная) и свои поля; у каждого — `<поле>_doc`.
3. Кадр: `tools/shots/easter_egg_shot.sh <id> build/screenshots/easter_eggs/<№>.jpg` (форс `--egg=<id>`,
   камера `--look-at=egg`, печатает `EGG_GPU_MS`; `--egg=none` — база для цены). Тест
   `tests/world_objects/test_easter_eggs.gd` подхватывает новую пасхалку из конфига сам.

Запрещено (тест проверяет часть): физические тела, `Area3D`, `RayCast3D`, запись в `ObstacleIndex`,
`world_link.objects`, столкновения; `randf`/`randi`/`shuffle`/`pick_random` и прочий глобальный
генератор (только `rng`); запись в чужие узлы (воздух, крыло, рельеф, боты, небо, камера, `Engine`);
тексты, подсказки, HUD; тени у мешей дальше ~1 км. Проба каркаса — `easter_eggs/probe.gd`
(в игре выключена, `--egg=probe`).

**Место (`egg_place.gd`, `EggPlace`, `ctx.place`; К8)**: дешёвые проверки «логично ли здесь» —
высота/крутизна/класс поверхности, дно долины и `is_mountain`, ближайшее пятно застройки (без имени), вода по покрову
и маске рек, старты, лагерь, `find_point(rng, …, accept)` для выбора точки. Строится планировщиком один раз на
полёт (≈1 мс), только читает; нет WorldCover/пятен — «нет» (места яиц тогда — опорные точки по рельефу) (`{}`/`[]`/INF/NONE). Пороги — `configs/easter_eggs.json → place`.
Рядом в `EggContext` — дата, высота солнца, облачность, ветер и температура прогноза.
