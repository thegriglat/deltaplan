---
type: "contract"
status: "closed"
module: "easter-eggs"
area: "world"
updated: "2026-10-15"
summary: "Контракты модуля «Пасхалки», К1–К16: версии модуля и инвариант (только картинка и звук), список стыков и ссылки на части."
related: ["docs/contracts/easter-eggs/framework.md", "docs/contracts/easter-eggs/place-world.md", "docs/contracts/easter-eggs/models-sound.md"]
contracts: [{"id": "К1", "version": 2}, {"id": "К2", "version": 3}, {"id": "К3", "version": 2}, {"id": "К4", "version": 2}, {"id": "К5", "version": 2}, {"id": "К6", "version": 4}, {"id": "К7", "version": 5}, {"id": "К8", "version": 9}, {"id": "К9", "version": 5}, {"id": "К10", "version": 7}, {"id": "К11", "version": 7}, {"id": "К12", "version": 7}, {"id": "К13", "version": 8}, {"id": "К14", "version": 8}, {"id": "К15", "version": 10}, {"id": "К16", "version": 10}]
---
# Контракты модуля «Пасхалки: живой мир и небо»

План — `docs/archive/plan/world-easter-eggs.md`, журнал — `docs/archive/plan/world-easter-eggs-progress.md`.
Владелец каркаса — задача **E0**; потребители — E1–E11. Менять интерфейс — только через
координатора модуля (версия +1, что изменилось, правка всех потребителей в том же шаге).

**Версия: 10** (11.10.2026). v9 → v10: К15 модель брелока-чайки (EE-9), К16 брелок на трапеции (EE-10).

Версия 9 (11.10.2026). v8 → v9: поле `EggContext.lat_deg` (К8, поставщик EE-6 — для сезонов перелёта гусей); К12 не реализуется (EE-5 отменена пользователем).

Версия 8 (11.10.2026). v7 → v8: К13 модель гуся, К14 звук гусиной стаи (EE-7 → EE-6 «Клин гусей»).

Версия 7 (11.10.2026). v6 → v7 (волна 3): К10 «Участки полей» `FieldPlots` (EE-1), К11 модель рулона сена (EE-2), К12 стёкла машин `OsmTraffic.glass()` и блики окон в шейдере стен (EE-5).

Версия 6 (10.10.2026). v5 → v6 (модуль no-osm): К8 v4 — `EggPlace` без OSM: `places()` из
пятен застройки WorldCover (или опорных точек по рельефу), `nearest_place` без имени/населения,
`near_water_m` по покрову и рекам рельефа, дороги удалены (УАЗ — бездорожье); NONE покрова — открытый грунт.

Версия 5 (01.10.2026). v4 → v5: перед E10 — К9 «другая группа»: доп. боты пасхалки — свой
экземпляр `BotPilots` внутри пасхалки, **не** в `game.bots`; ключ мира и сравнение ботов в К7 —
только по ботам игры; в К7 добавлена проверка «число ботов игры и ключ мира с пасхалками те же».

Версия 4 (30.09.2026). v3 → v4: ключ кадра `--fov=<°>` (К6) — дальние пасхалки (Ан-2 в ≥ 6 км)
иначе в кадре в 3 пикселя; поставщик — E3. Пары замера цены — с одинаковым взглядом
(`--look-at=start`).

Версия 3 (30.09.2026). v2 → v3: требование пользователя «появление привязано к месту и
условиям» — поля даты и погоды в `EggContext` и общий API места `EggPlace` (К8), таблица условий
— в плане (`docs/archive/plan/world-easter-eggs.md` → «Условия появления»). Поставщик — задача **E0б**;
E1, E2, E5 (небо) К8 не нужен, их условия уже в К2.

Версия 2 (30.09.2026). v1 → v2 (после E0, по коду): `step(ctx)` и поля для тестов (К1);
`lifetime_s` обязателен (К3, К5); уточнения порядка бросков и прыжка времени (К4); `--gpu-report`,
вызовы отрисовки в отчёте кадра, форс выключенной по имени (К6); цена — не только время GPU.

Главный инвариант модуля: **пасхалки — только картинка (и звук)**. Физика полёта, атмосфера,
боты, столкновения, счёт и итог полёта с пасхалками и без них совпадают **побитно** (К7).

## Стыки и части

Контракт разбит по D4 (`docs/contracts/docs-rework.md`): каждый стык целиком в одной части, номера К1…К16 не менялись (на них ссылаются код и тесты). Версия стыка в таблице — по заголовку раздела; у К1–К7 в заголовках версии нет, там указан номер версии модуля последней правки по истории выше; у К8 в заголовке v4 (пятно застройки без OSM), текущая v9 (поле `lat_deg`).

| Стык | Версия | Что | Часть |
|---|---|---|---|
| К1 | v2 | планировщик ↔ Game | [framework](easter-eggs/framework.md) |
| К2 | v3 | контекст пасхалки `EggContext` | [framework](easter-eggs/framework.md) |
| К3 | v2 | пасхалка `EasterEgg` | [framework](easter-eggs/framework.md) |
| К4 | v2 | расписание и детерминизм | [framework](easter-eggs/framework.md) |
| К5 | v2 | конфиг `configs/easter_eggs.json` | [framework](easter-eggs/framework.md) |
| К6 | v4 | форс для кадров — ключ запуска | [framework](easter-eggs/framework.md) |
| К7 | v5 | тест «не трогает физику» | [framework](easter-eggs/framework.md) |
| К8 | v9 | место и условия — `EggPlace` и поля контекста | [place-world](easter-eggs/place-world.md) |
| К9 | v5 | другая группа — доп. боты пасхалки | [place-world](easter-eggs/place-world.md) |
| К10 | v7 | участки полей `FieldPlots` | [place-world](easter-eggs/place-world.md) |
| К11 | v7 | модель рулона сена | [place-world](easter-eggs/place-world.md) |
| К12 | v7 | стёкла машин `OsmTraffic.glass()` (не реализуется, EE-5 отменена) | [place-world](easter-eggs/place-world.md) |
| К13 | v8 | модель гуся | [models-sound](easter-eggs/models-sound.md) |
| К14 | v8 | звук гусиной стаи | [models-sound](easter-eggs/models-sound.md) |
| К15 | v10 | модель брелока-чайки | [models-sound](easter-eggs/models-sound.md) |
| К16 | v10 | брелок на трапеции `bar_charm` | [models-sound](easter-eggs/models-sound.md) |

- [easter-eggs/framework.md](easter-eggs/framework.md) — К1–К7: каркас.
- [easter-eggs/place-world.md](easter-eggs/place-world.md) — К8–К12: место, группа, поля, рулоны, стёкла.
- [easter-eggs/models-sound.md](easter-eggs/models-sound.md) — К13–К16: модели и звук.
