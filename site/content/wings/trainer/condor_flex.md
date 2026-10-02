---
title: "Delta Flugschule Condor FLEX"
weight: 5
description: "Delta Flugschule Condor FLEX: мачтовое крыло, прототип — Delta Flugschule Condor FLEX / Lifter (2019–). Размах 9,2 м, площадь 16 м², масса 17,6 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Delta Flugschule Condor FLEX

**Прототип:** Delta Flugschule Condor FLEX / Lifter · **годы:** 2019– · **группа:** [Учебные однообшивочные](/wings/trainer/) · **мачтовое**

![Модель Delta Flugschule Condor FLEX в игре (рендер Blender)](/docs/models/screenshots/glider_condor_flex/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/condor_flex.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#отметки-происхождения).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 9,2 м | **паспорт**: [карточка DHV 01-0496-19](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Spannweite 9.2 m» |
| Площадь | 16 м² | **паспорт**: [карточка DHV 01-0496-19](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «FlÃ¤che 16.0 m2» |
| Масса крыла | 17,6 кг | **паспорт**: [карточка DHV 01-0496-19](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Gewicht (ohne Packsack) 17.6 Kg» |
| Масса пилота с подвеской | 49–97 кг | **оценка**: DHV «Startgewicht» 67–115 кг минус масса крыла 17,6 кг ([карточка DHV 01-0496-19](https://service.dhv.de/db1/technicsearchpage.php?lang=DE); hook-in в паспорте нет) |
| Двойная обшивка | 20 % размаха | **паспорт**: [карточка DHV 01-0496-19](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Doppelsegel 20.0 %» |
| Мачта | есть (мачтовое) | **оценка**: по году выпуска и классу, подтверждающей цитаты нет (ТЗ, раздел N6) |
| Класс / сертификат | DHV 1 (DHV 01-0496-19) | **паспорт**: [карточка DHV 01-0496-19](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2019– | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N6) |
| DHV Vmin (VG 0) | 29 км/ч (стартовая масса 67–115 кг) | **паспорт**: [карточка DHV 01-0496-19](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| DHV Vmax (VG 0) | 65 км/ч | **паспорт**: [карточка DHV 01-0496-19](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Скорость трима | 31,9 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 0,92) |
| Скорость, трапеция полностью на себя | 63,8 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 0,92) |
| Сваливание (прямой полёт) | 28,6 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 0,92) |
| Минимальное снижение | 0,997 м/с на 29,8 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 0,92) |
| Качество | 9 на 37,9 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 0,92); подобие качество не меняет — как у базы |
| Ветер на старте до | 8 м/с | **оценка**: подсказка меню игры, как у базы Wills Wing Falcon 170 |
| Эталонная масса пилота (для поляры) | 70 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Wills Wing Falcon 170 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/condor_flex.json](/configs/wings/condor_flex.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N6](/docs/research/glider_3d_tz.md#раздел-n6-delta-flugschule-condor-flex--lifter-condor_flex--новая-модель-приоритет-p2)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#благодарности">благодарность на главной</a>
