---
title: "Delta Flugschule Condor Crex 3"
weight: 4
description: "Delta Flugschule Condor Crex 3: мачтовое крыло, прототип — Delta Flugschule Condor Crex 3 (2015–). Размах 9,6 м, площадь 14,5 м², масса 23 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Delta Flugschule Condor Crex 3

**Прототип:** Delta Flugschule Condor Crex 3 · **годы:** 2015– · **группа:** [Учебные](/wings/trainer/) · **мачтовое**

![Модель Delta Flugschule Condor Crex 3 в игре (рендер Blender)](/docs/models/screenshots/glider_condor_crex3/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/condor_crex3.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#provenance-marks).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 9,6 м | **паспорт**: [карточка DHV 01-0505-24](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Spannweite  9.6 m» |
| Площадь | 14,5 м² | **паспорт**: [карточка DHV 01-0505-24](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «FlÃ¤che  14.5 m2» |
| Масса крыла | 23 кг | **паспорт**: [карточка DHV 01-0505-24](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Gewicht (ohne Packsack)  23.0 Kg» |
| Масса пилота с подвеской | 49–98 кг | **оценка**: DHV «Startgewicht» 72–121 кг минус масса крыла 23 кг ([карточка DHV 01-0505-24](https://service.dhv.de/db1/technicsearchpage.php?lang=DE); hook-in в паспорте нет) |
| Двойная обшивка | 60 % размаха | **паспорт**: [карточка DHV 01-0505-24](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Doppelsegel  60.0 %» |
| Мачта | есть (мачтовое) | **оценка**: по году выпуска и классу, подтверждающей цитаты нет (ТЗ, раздел N5) |
| Класс / сертификат | DHV 1 (DHV 01-0505-24) | **паспорт**: [карточка DHV 01-0505-24](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2015– | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N5) |
| DHV Vmin (VG 0) | 35 км/ч (стартовая масса 72–121 кг) | **паспорт**: [карточка DHV 01-0505-24](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| DHV Vmax (VG 0) | 80 км/ч | **паспорт**: [карточка DHV 01-0505-24](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Скорость трима | 38,7 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 1,0011) |
| Скорость, трапеция полностью на себя | 79 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 1,0011) |
| Сваливание (прямой полёт) | 34,7 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 1,0011) |
| Минимальное снижение | 1,212 м/с на 36,3 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 1,0011) |
| Качество | 9 на 46 км/ч | **оценка**: модель игры: поляра базы Wills Wing Falcon 170 подобием по нагрузке на крыло (f = 1,0011); подобие качество не меняет — как у базы |
| Ветер на старте | учебный, 7–10 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 71 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Wills Wing Falcon 170 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/condor_crex3.json](/configs/wings/condor_crex3.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N5](/docs/research/glider_3d_tz.md#раздел-n5-delta-flugschule-condor-crex-3-condor_crex3--новая-модель-приоритет-p2)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#acknowledgements">благодарность на главной</a>
