---
title: "Seedwings Skyrunner XR"
weight: 16
description: "Seedwings Skyrunner XR: мачтовое крыло, прототип — Seedwings Skyrunner XR (2013). Размах 10,2 м, площадь 14,2 м², масса 32,8 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Seedwings Skyrunner XR

**Прототип:** Seedwings Skyrunner XR · **годы:** 2013 · **группа:** [Мачтовые двухобшивочные](/wings/kingpost/) · **мачтовое**

![Модель Seedwings Skyrunner XR в игре (рендер Blender)](/docs/models/screenshots/glider_seed_skyrunner_xr/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/seed_skyrunner_xr.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#отметки-происхождения).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 10,2 м | **паспорт**: [карточка DHV 01-0475-13](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «10.2 m» |
| Площадь | 14,2 м² | **паспорт**: [карточка DHV 01-0475-13](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «14.2 m2» |
| Масса крыла | 32,8 кг | **паспорт**: [карточка DHV 01-0475-13](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «32.8 Kg *)» |
| Масса пилота с подвеской | 67–117 кг | **оценка**: DHV «Startgewicht» 100–150 кг минус масса крыла 32,8 кг ([карточка DHV 01-0475-13](https://service.dhv.de/db1/technicsearchpage.php?lang=DE); hook-in в паспорте нет) |
| Двойная обшивка | 90 % размаха | **паспорт**: [карточка DHV 01-0475-13](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «90.0 %» |
| Мачта | есть (мачтовое) | **оценка**: по цитате не с сайта производителя: [en.wikipedia.org](https://en.wikipedia.org/wiki/Seedwings_Europe) |
| Класс / сертификат | DHV 2-3 (DHV 01-0475-13) | **паспорт**: [карточка DHV 01-0475-13](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2013 | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N36) |
| DHV Vmin (VG 0) | 31 км/ч (стартовая масса 100–150 кг) | **паспорт**: [карточка DHV 01-0475-13](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| DHV Vmax (VG 0) | 90 км/ч | **паспорт**: [карточка DHV 01-0475-13](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Скорость трима | 37,7 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,077) |
| Скорость, трапеция полностью на себя | 91,5 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,077) |
| Сваливание (прямой полёт) | 28,3 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,077) |
| Минимальное снижение | 0,969 м/с на 40,9 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,077) |
| Качество | 13,2 на 49,5 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,077); подобие качество не меняет — как у базы |
| Ветер на старте до | 10 м/с | **оценка**: подсказка меню игры, как у базы Icaro Laminar Easy 14 |
| Эталонная масса пилота (для поляры) | 95 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Icaro Laminar Easy 14 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/seed_skyrunner_xr.json](/configs/wings/seed_skyrunner_xr.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N36](/docs/research/glider_3d_tz.md#раздел-n36-seedwings-skyrunner-xr-seed_skyrunner_xr--новая-модель-приоритет-p2)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#благодарности">благодарность на главной</a>
