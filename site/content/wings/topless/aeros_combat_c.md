---
title: "Aeros Combat C 12.7"
weight: 9
description: "Aeros Combat C 12.7: безмачтовое крыло, прототип — Aeros Combat C (и DesignProducts Combat C AC) (2012–). Размах 10,3 м, площадь 12,7 м², масса 31,3 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Aeros Combat C 12.7

**Прототип:** Aeros Combat C (и DesignProducts Combat C AC) · **годы:** 2012– · **группа:** [Безмачтовые](/wings/topless/) · **безмачтовое**

![Модель Aeros Combat C 12.7 в игре (рендер Blender)](/docs/models/screenshots/glider_aeros_combat_c/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/aeros_combat_c.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#отметки-происхождения).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 10,3 м | **паспорт**: [карточка DHV 01-0489-16](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Spannweite 10.3 m» |
| Площадь | 12,7 м² | **паспорт**: [карточка DHV 01-0489-16](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Fläche 12.7 m2» |
| Масса крыла | 31,3 кг | **паспорт**: [карточка DHV 01-0489-16](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Gewicht (ohne Packsack) 31.3 Kg» |
| Масса пилота с подвеской | 80–100 кг | **оценка**: DHV «Startgewicht» 111–131 кг минус масса крыла 31,3 кг ([карточка DHV 01-0489-16](https://service.dhv.de/db1/technicsearchpage.php?lang=DE); hook-in в паспорте нет) |
| Двойная обшивка | 90 % размаха | **паспорт**: [карточка DHV 01-0489-16](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Doppelsegel 90.0 %» |
| Мачта | нет (безмачтовое) | **паспорт**: цитата со страницы производителя: [aeros.com.ua](https://aeros.com.ua/combat_c) |
| Класс / сертификат | DHV 3 (DHV 01-0489-16) | **паспорт**: [карточка DHV 01-0489-16](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2012– | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N29) |
| DHV Vmin (VG 0) | 32 км/ч (стартовая масса 111–131 кг) | **паспорт**: [карточка DHV 01-0489-16](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| DHV Vmax (VG 0) | 90 км/ч | **паспорт**: [карточка DHV 01-0489-16](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Скорость трима | 37,3 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 1,0082) |
| Скорость, трапеция полностью на себя | 89,7 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 1,0082) |
| Сваливание (прямой полёт) | 32 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 1,0082) |
| Минимальное снижение | 0,847 м/с на 41,4 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 1,0082) |
| Качество | 16 на 50,5 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 1,0082); подобие качество не меняет — как у базы |
| Ветер на старте | безмачтовый, 20–25 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 89 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Aeros Combat GT 13.2 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/aeros_combat_c.json](/configs/wings/aeros_combat_c.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N29](/docs/research/glider_3d_tz.md#раздел-n29-aeros-combat-c-и-designproducts-combat-c-ac-aeros_combat_c--новая-модель-приоритет-p1)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#благодарности">благодарность на главной</a>
