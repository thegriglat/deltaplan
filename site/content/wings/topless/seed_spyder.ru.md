---
title: "Seedwings Spyder 12.5"
weight: 3
description: "Seedwings Spyder 12.5: безмачтовое крыло, прототип — Seedwings Spyder (2004). Размах 9,8 м, площадь 12,5 м², масса 28,5 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Seedwings Spyder 12.5

**Прототип:** Seedwings Spyder · **годы:** 2004 · **группа:** [Безмачтовые](/wings/topless/) · **безмачтовое**

![Модель Seedwings Spyder 12.5 в игре (рендер Blender)](/docs/models/screenshots/glider_seed_spyder/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/seed_spyder.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#provenance-marks).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 9,8 м | **паспорт**: [карточка DHV 01-0410-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Spannweite  9.8 m» |
| Площадь | 12,5 м² | **паспорт**: [карточка DHV 01-0410-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «FlÃ¤che  12.5 m2» |
| Масса крыла | 28,5 кг | **паспорт**: [карточка DHV 01-0410-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Gewicht (ohne Packsack)  28.5 Kg» |
| Масса пилота с подвеской | 56–82 кг | **оценка**: DHV «Startgewicht» 84–110 кг минус масса крыла 28,5 кг ([карточка DHV 01-0410-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE); hook-in в паспорте нет) |
| Двойная обшивка | 82 % размаха | **паспорт**: [карточка DHV 01-0410-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Doppelsegel  82.0 %» |
| Мачта | нет (безмачтовое) | **оценка**: по цитате не с сайта производителя: [delta-club-82.com](https://www.delta-club-82.com/bible/494-hang-glider-spyder.htm) |
| Класс / сертификат | DHV 2 (DHV 01-0410-05) | **паспорт**: [карточка DHV 01-0410-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2004 | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N19) |
| DHV Vmin (VG 0) | 33 км/ч (стартовая масса 84–110 кг) | **паспорт**: [карточка DHV 01-0410-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| DHV Vmax (VG 0) | 90 км/ч | **паспорт**: [карточка DHV 01-0410-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Скорость трима | 36,7 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 0,9498) |
| Скорость, трапеция полностью на себя | 81,9 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 0,9498) |
| Сваливание (прямой полёт) | 32,8 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 0,9498) |
| Минимальное снижение | 0,783 м/с на 34,2 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 0,9498) |
| Качество | 15 на 43,1 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 0,9498); подобие качество не меняет — как у базы |
| Ветер на старте | безмачтовый, 20–25 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 67 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Moyes Litespeed RS 4 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/seed_spyder.json](/configs/wings/seed_spyder.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N19](/docs/research/glider_3d_tz.md#раздел-n19-seedwings-spyder-seed_spyder--новая-модель-приоритет-p2)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#acknowledgements">благодарность на главной</a>
