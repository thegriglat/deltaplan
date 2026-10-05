---
title: "Airborne Sting 3 154"
weight: 7
description: "Airborne Sting 3 154: мачтовое крыло, прототип — Airborne Sting 3 (2008). Размах 9,1 м, площадь 14,33 м², масса 26,3 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Airborne Sting 3 154

**Прототип:** Airborne Sting 3 · **годы:** 2008 · **группа:** [Мачтовые](/wings/kingpost/) · **мачтовое**

![Модель Airborne Sting 3 154 в игре (рендер Blender)](/docs/models/screenshots/glider_air_sting3/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/air_sting3.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#provenance-marks).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 9,1 м | **паспорт**: [руководство Airborne Sting 3 (PDF)](https://www.airborne.com.au/images/manuals/108841%20STING%203%20Manual.pdf) «WING SPAN 9.1 m»; [карточка DHV 01-0438-08](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «9.1 m» |
| Площадь | 14,33 м² | **паспорт**: [руководство Airborne Sting 3 (PDF)](https://www.airborne.com.au/images/manuals/108841%20STING%203%20Manual.pdf) «SAIL AREA 14.33 sq meter»; [карточка DHV 01-0438-08](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «14.33 m2» |
| Масса крыла | 26,3 кг | **паспорт**: [руководство Airborne Sting 3 (PDF)](https://www.airborne.com.au/images/manuals/108841%20STING%203%20Manual.pdf) «GLIDER WEIGHT 26 kg»; [карточка DHV 01-0438-08](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «26.3 Kg *)» |
| Масса пилота с подвеской | 50–100 кг | **паспорт**: [руководство Airborne Sting 3 (PDF)](https://www.airborne.com.au/images/manuals/108841%20STING%203%20Manual.pdf) «RECOMMENDED PILOT HOOK IN WEIGHT RANGE 50-100 kg» |
| Двойная обшивка | 75 % размаха | **паспорт**: [руководство Airborne Sting 3 (PDF)](https://www.airborne.com.au/images/manuals/108841%20STING%203%20Manual.pdf) «DOUBLE SURFACE 75%»; [карточка DHV 01-0438-08](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «75.0 %» |
| Мачта | есть (мачтовое) | **паспорт**: цитата со страницы производителя: [airborne.com.au](https://www.airborne.com.au/images/manuals/Sting-3-Rev1-Manual.pdf) |
| Класс / сертификат | DHV 2 (DHV 01-0438-08) | **паспорт**: [карточка DHV 01-0438-08](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2008 | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N13) |
| DHV Vmin (VG 0) | 29 км/ч (стартовая масса 76–126 кг) | **паспорт**: [карточка DHV 01-0438-08](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| DHV Vmax (VG 0) | 85 км/ч | **паспорт**: [карточка DHV 01-0438-08](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Скорость трима | 33,9 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 0,9686) |
| Скорость, трапеция полностью на себя | 86,4 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 0,9686) |
| Сваливание (прямой полёт) | 29,6 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 0,9686) |
| Минимальное снижение | 0,872 м/с на 36,8 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 0,9686) |
| Качество | 13,2 на 44,5 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 0,9686); подобие качество не меняет — как у базы |
| Ветер на старте | плавающая поперечина, 12–15 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 78 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Icaro Laminar Easy 14 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/air_sting3.json](/configs/wings/air_sting3.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N13](/docs/research/glider_3d_tz.md#раздел-n13-airborne-sting-3-air_sting3--новая-модель-приоритет-p1)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#acknowledgements">благодарность на главной</a>
