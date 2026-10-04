---
title: "Flugsport Skypoint Crossover 14"
weight: 11
description: "Flugsport Skypoint Crossover 14: мачтовое крыло, прототип — Flugsport Skypoint Crossover (годы неизвестны). Размах 9,9 м, площадь 14 м², масса 28,2 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Flugsport Skypoint Crossover 14

**Прототип:** Flugsport Skypoint Crossover · **годы:** годы неизвестны · **группа:** [Мачтовые](/wings/kingpost/) · **мачтовое**

![Модель Flugsport Skypoint Crossover 14 в игре (рендер Blender)](/docs/models/screenshots/glider_fs_crossover/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/fs_crossover.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#отметки-происхождения).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 9,9 м | **паспорт**: [карточка DHV 01-0459-11](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «9.9 m» |
| Площадь | 14 м² | **паспорт**: [карточка DHV 01-0459-11](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «14.0 m2» |
| Масса крыла | 28,2 кг | **паспорт**: [карточка DHV 01-0459-11](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «28.2 Kg *)» |
| Масса пилота с подвеской | 62–110 кг | **оценка**: DHV «Startgewicht» 90–138 кг минус масса крыла 28,2 кг ([карточка DHV 01-0459-11](https://service.dhv.de/db1/technicsearchpage.php?lang=DE); hook-in в паспорте нет) |
| Двойная обшивка | 82 % размаха | **паспорт**: [карточка DHV 01-0459-11](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «82.0 %» |
| Мачта | есть (мачтовое) | **оценка**: по году выпуска и классу, подтверждающей цитаты нет (ТЗ, раздел N18) |
| Класс / сертификат | DHV 2 (DHV 01-0459-11) | **паспорт**: [карточка DHV 01-0459-11](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | неизвестно | **оценка**: в паспортах и выборке нет |
| Скорость трима | 36,4 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0387) |
| Скорость, трапеция полностью на себя | 88,3 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0387) |
| Сваливание (прямой полёт) | 27,3 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0387) |
| Минимальное снижение | 0,935 м/с на 39,5 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0387) |
| Качество | 13,2 на 47,8 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0387); подобие качество не меняет — как у базы |
| Ветер на старте | плавающая поперечина, 12–15 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 89 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Icaro Laminar Easy 14 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/fs_crossover.json](/configs/wings/fs_crossover.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N18](/docs/research/glider_3d_tz.md#раздел-n18-flugsport-skypoint-crossover-fs_crossover--новая-модель-приоритет-p2)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#благодарности">благодарность на главной</a>
