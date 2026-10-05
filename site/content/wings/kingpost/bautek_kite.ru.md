---
title: "Bautek Kite"
weight: 10
description: "Bautek Kite: мачтовое крыло, прототип — Bautek Kite (2006–). Размах 10,15 м, площадь 13,8 м², масса 30,4 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Bautek Kite

**Прототип:** Bautek Kite · **годы:** 2006– · **группа:** [Мачтовые](/wings/kingpost/) · **мачтовое**

![Модель Bautek Kite в игре (рендер Blender)](/docs/models/screenshots/glider_bautek_kite/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/bautek_kite.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#provenance-marks).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 10,15 м | **паспорт**: [bautek.com: Kite](https://www.bautek.com/english/hanggliders/kite/) «Span: 33 ft, [10.15 m]»; [карточка DHV 01-0421-06](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «10.15 m» |
| Площадь | 13,8 м² | **паспорт**: [bautek.com: Kite](https://www.bautek.com/english/hanggliders/kite/) «Sail-area: 149 sft, [13.8 sm]»; [карточка DHV 01-0421-06](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «13.8 m2» |
| Масса крыла | 30,4 кг | **паспорт**: [карточка DHV 01-0421-06](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «30.4 Kg *)»; другой источник: [bautek.com: Kite](https://www.bautek.com/english/hanggliders/kite/) 29,5 кг |
| Масса пилота с подвеской, мин. | 60 кг | **оценка**: DHV «Startgewicht» 90–149 кг минус масса крыла 30,4 кг ([карточка DHV 01-0421-06](https://service.dhv.de/db1/technicsearchpage.php?lang=DE); hook-in в паспорте нет) |
| Масса пилота с подвеской, макс. | 120 кг | **паспорт**: [bautek.com: Kite](https://www.bautek.com/english/hanggliders/kite/) «Hook-in weight: max 265 Lbs, [120kg]» |
| Двойная обшивка | 85 % размаха | **паспорт**: [bautek.com: Kite](https://www.bautek.com/english/hanggliders/kite/) «Double surface: ca. 85 %»; [карточка DHV 01-0421-06](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) «85.0 %» |
| Мачта | есть (мачтовое) | **паспорт**: цитата со страницы производителя: [bautek.com](https://www.bautek.com/english/hanggliders/kite/) |
| Класс / сертификат | DHV 2 (DHV 01-0421-06) | **паспорт**: [карточка DHV 01-0421-06](https://service.dhv.de/db1/technicsearchpage.php?lang=DE) |
| Годы выпуска | 2006– | **оценка**: выборка страниц производителя / год сертификации (ТЗ, раздел N16) |
| Скорость трима | 28,6 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0779) |
| Скорость, трапеция полностью на себя | 69,6 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0779) |
| Сваливание (прямой полёт) | 25,5 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0779) |
| Минимальное снижение | 0,738 м/с на 31,2 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0779) |
| Качество | 13,2 на 37,7 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0779); подобие качество не меняет — как у базы |
| Ветер на старте | плавающая поперечина, 12–15 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 94 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Icaro Laminar Easy 14 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/bautek_kite.json](/configs/wings/bautek_kite.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N16](/docs/research/glider_3d_tz.md#раздел-n16-bautek-kite-bautek_kite--новая-модель-приоритет-p2)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#acknowledgements">благодарность на главной</a>
