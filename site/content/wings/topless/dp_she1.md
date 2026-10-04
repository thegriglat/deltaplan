---
title: "DesignProducts SHE 1 12.7"
weight: 14
description: "DesignProducts SHE 1 12.7: безмачтовое крыло, прототип — DesignProducts SHE 1 (2023–). Размах 10,35 м, площадь 12,7 м², масса 28,4 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# DesignProducts SHE 1 12.7

**Прототип:** DesignProducts SHE 1 · **годы:** 2023– · **группа:** [Безмачтовые](/wings/topless/) · **безмачтовое**

![Модель DesignProducts SHE 1 12.7 в игре (рендер Blender)](/docs/models/screenshots/glider_dp_she1/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/dp_she1.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#отметки-происхождения).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 10,35 м | **паспорт**: [карточка DHV 01-0504-23](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Spannweite 10.35 m» |
| Площадь | 12,7 м² | **паспорт**: [карточка DHV 01-0504-23](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «FlÃ¤che 12.7 m2» |
| Масса крыла | 28,4 кг | **паспорт**: [карточка DHV 01-0504-23](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Gewicht (ohne Packsack) 28.4 Kg» |
| Масса пилота с подвеской | 70–101 кг | **оценка**: DHV «Startgewicht» 98–129 кг минус масса крыла 28,4 кг ([карточка DHV 01-0504-23](https://service.dhv.de/db1/technicsearchpage.php?lang=DE); hook-in в паспорте нет) |
| Двойная обшивка | 90 % размаха | **паспорт**: [карточка DHV 01-0504-23](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Doppelsegel 90.0 %» |
| Мачта | нет (безмачтовое) | **оценка**: по году выпуска и классу, подтверждающей цитаты нет (ТЗ, раздел N35) |
| Класс / сертификат | DHV 3 (DHV 01-0504-23) | **паспорт**: [карточка DHV 01-0504-23](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2023– | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N35) |
| DHV Vmin (VG 0) | 38 км/ч (стартовая масса 98–129 кг) | **паспорт**: [карточка DHV 01-0504-23](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Скорость трима | 42,4 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9746) |
| Скорость, трапеция полностью на себя | 97,5 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9746) |
| Сваливание (прямой полёт) | 37,9 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9746) |
| Минимальное снижение | 0,819 м/с на 43,8 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9746) |
| Качество | 16 на 48,9 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9746); подобие качество не меняет — как у базы |
| Ветер на старте | безмачтовый, 20–25 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 84 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Aeros Combat GT 13.2 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/dp_she1.json](/configs/wings/dp_she1.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N35](/docs/research/glider_3d_tz.md#раздел-n35-designproducts-she-1-dp_she1--новая-модель-приоритет-p2)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#благодарности">благодарность на главной</a>
