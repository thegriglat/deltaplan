---
title: "Icaro MastR L"
weight: 19
description: "Icaro MastR L: мачтовое крыло, прототип — Icaro MastR (2007–). Размах 10,4 м, площадь 14,8 м², масса 31,5 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Icaro MastR L

**Прототип:** Icaro MastR · **годы:** 2007– · **группа:** [Мачтовые](/wings/kingpost/) · **мачтовое**

![Модель Icaro MastR L в игре (рендер Blender)](/docs/models/screenshots/glider_icaro_mastr/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/icaro_mastr.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#отметки-происхождения).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 10,4 м | **паспорт**: [icaro2000.com: MastR](https://www.icaro2000.com/Products/Hanggliders/MastR/MastR.htm) «Wingspan ml 10.48»; [карточка DHV 01-0443-09](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «10.4 m» |
| Площадь | 14,8 м² | **паспорт**: [icaro2000.com: MastR](https://www.icaro2000.com/Products/Hanggliders/MastR/MastR.htm) «Area m2 14.88»; [карточка DHV 01-0443-09](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «14.8 m2» |
| Масса крыла | 31,5 кг | **паспорт**: [карточка DHV 01-0443-09](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «31.5 Kg *)» |
| Масса пилота с подвеской | 85–110 кг | **паспорт**: [icaro2000.com: MastR](https://www.icaro2000.com/Products/Hanggliders/MastR/MastR.htm) «Pilot hook-in weight (min / max) kg 85/110» |
| Двойная обшивка | 94 % размаха | **паспорт**: [icaro2000.com: MastR](https://www.icaro2000.com/Products/Hanggliders/MastR/MastR.htm) «Double surface % 94»; [карточка DHV 01-0443-09](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «94.0 %» |
| Мачта | есть (мачтовое) | **оценка**: решение по ТЗ (раздел N15; wings3d_overrides/icaro_mastr.json) |
| Класс / сертификат | DHV 3 (DHV 01-0443-09) | **паспорт**: [карточка DHV 01-0443-09](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2007– | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N15) |
| DHV Vmin (VG 0) | 32 км/ч (стартовая масса 95–146 кг) | **паспорт**: [карточка DHV 01-0443-09](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| DHV Vmax (VG 0) | 74 км/ч | **паспорт**: [карточка DHV 01-0443-09](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Скорость трима | 36,9 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9615) |
| Скорость, трапеция полностью на себя | 76,1 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9615) |
| Сваливание (прямой полёт) | 33 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9615) |
| Минимальное снижение | 0,808 м/с на 43,3 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9615) |
| Качество | 16 на 48,1 км/ч | **оценка**: модель игры: поляра базы Aeros Combat GT 13.2 подобием по нагрузке на крыло (f = 0,9615); подобие качество не меняет — как у базы |
| Ветер на старте | плавающая поперечина, 12–15 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 96 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Aeros Combat GT 13.2 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/icaro_mastr.json](/configs/wings/icaro_mastr.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N15](/docs/research/glider_3d_tz.md#раздел-n15-icaro-mastr-icaro_mastr--новая-модель-приоритет-p1)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#благодарности">благодарность на главной</a>
