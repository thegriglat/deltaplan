---
title: "Moyes Litespeed S 4"
weight: 2
description: "Moyes Litespeed S 4: безмачтовое крыло, прототип — Moyes Litespeed S (2005). Размах 10 м, площадь 13,7 м², масса 36 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Moyes Litespeed S 4

**Прототип:** Moyes Litespeed S · **годы:** 2005 · **группа:** [Безмачтовые](/wings/topless/) · **безмачтовое**

![Модель Moyes Litespeed S 4 в игре (рендер Blender)](/docs/models/screenshots/glider_moyes_litespeed_s/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/moyes_litespeed_s.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#provenance-marks).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 10 м | **паспорт**: [руководство Moyes Litespeed S (PDF)](https://www.delta-club-82.com/bible/manuels/litespeed-S.pdf) «Span 10 m», «Span 32.8 ft»; [карточка DHV 01-0403-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Spannweite 10.0 m» |
| Площадь | 13,7 м² | **паспорт**: [руководство Moyes Litespeed S (PDF)](https://www.delta-club-82.com/bible/manuels/litespeed-S.pdf) «Area 13.7 sq m», «Area 147 sq ft»; [карточка DHV 01-0403-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «FlÃ¤che 13.7 m2» |
| Масса крыла | 36 кг | **паспорт**: [карточка DHV 01-0403-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Gewicht (ohne Packsack) 36.0 Kg»; другой источник: [руководство Moyes Litespeed S (PDF)](https://www.delta-club-82.com/bible/manuels/litespeed-S.pdf) 33,6 кг |
| Масса пилота с подвеской | 68–109 кг | **паспорт**: [руководство Moyes Litespeed S (PDF)](https://www.delta-club-82.com/bible/manuels/litespeed-S.pdf) «Hook-In-Weight 68-109kg», «Hook-In-Weight 150-240 lb» |
| Двойная обшивка | 92 % размаха | **паспорт**: [карточка DHV 01-0403-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «Doppelsegel 92.0 %» |
| Мачта | нет (безмачтовое) | **оценка**: по цитате не с сайта производителя: [en.wikipedia.org](https://en.wikipedia.org/wiki/Moyes_Litespeed) |
| Класс / сертификат | DHV 3 (DHV 01-0403-05) | **паспорт**: [карточка DHV 01-0403-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2005 | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N27) |
| DHV Vmin (VG 0) | 30 км/ч (стартовая масса 107–132 кг) | **паспорт**: [карточка DHV 01-0403-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| DHV Vmax (VG 0) | 80 км/ч | **паспорт**: [карточка DHV 01-0403-05](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Скорость трима | 33,6 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 1,0255) |
| Скорость, трапеция полностью на себя | 80,8 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 1,0255) |
| Сваливание (прямой полёт) | 30,4 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 1,0255) |
| Минимальное снижение | 0,812 м/с на 35,6 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 1,0255) |
| Качество | 15 на 44,6 км/ч | **оценка**: модель игры: поляра базы Moyes Litespeed RS 4 подобием по нагрузке на крыло (f = 1,0255); подобие качество не меняет — как у базы |
| Ветер на старте | безмачтовый, 20–25 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 86 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Moyes Litespeed RS 4 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/moyes_litespeed_s.json](/configs/wings/moyes_litespeed_s.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N27](/docs/research/glider_3d_tz.md#раздел-n27-moyes-litespeed-s-moyes_litespeed_s--новая-модель-приоритет-p2)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#acknowledgements">благодарность на главной</a>
