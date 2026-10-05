---
title: "Bautek Astir"
weight: 8
description: "Bautek Astir: мачтовое крыло, прототип — Bautek Astir (годы неизвестны). Размах 10,55 м, площадь 14,68 м², масса 29 кг; откуда каждое число."
---

<!-- Страница сгенерирована tools/site/gen_wings.py из configs/wings и паспортов — руками не править -->

# Bautek Astir

**Прототип:** Bautek Astir · **годы:** годы неизвестны · **группа:** [Мачтовые](/wings/kingpost/) · **мачтовое**

![Модель Bautek Astir в игре (рендер Blender)](/docs/models/screenshots/glider_bautek_astir/iso45.jpg)

## Данные

Числа — как в игре (`configs/wings/bautek_astir.json`). Отметки: **паспорт**, **аналог**, **оценка** — [что значат](/wings/#отметки-происхождения).

| Параметр | Значение | Откуда |
|---|---|---|
| Размах | 10,55 м | **паспорт**: [bautek.com: Astir](https://www.bautek.com/english/hanggliders/astir/) «Span: 34.6 ft» |
| Площадь | 14,68 м² | **паспорт**: [bautek.com: Astir](https://www.bautek.com/english/hanggliders/astir/) «Sail area: 158 sqft.» |
| Масса крыла | 29 кг | **паспорт**: [bautek.com: Astir](https://www.bautek.com/english/hanggliders/astir/) «Glider weight: 64 Lbs, without cover» |
| Масса пилота с подвеской | 60–115 кг | **паспорт**: мин. — [bautek.com: Astir](https://www.bautek.com/english/hanggliders/astir/) «Pilot weight: min 132 Lbs»; макс. — [bautek.com: Astir](https://www.bautek.com/english/hanggliders/astir/) «Pilot weight: max 253 Lbs» |
| Двойная обшивка | 85 % размаха | **паспорт**: [bautek.com: Astir](https://www.bautek.com/english/hanggliders/astir/) «Double surface: 85%» |
| Мачта | есть (мачтовое) | **оценка**: по году выпуска и классу, подтверждающей цитаты нет (ТЗ, раздел N17) |
| Класс / сертификат | DHV 2 | **паспорт**: [bautek.com: Astir](https://www.bautek.com/english/hanggliders/astir/) |
| Годы выпуска | неизвестно | **оценка**: в паспортах и выборке нет |
| Скорость трима | 28,6 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0264) |
| Скорость, трапеция полностью на себя | 69,4 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0264) |
| Сваливание (прямой полёт) | 25,4 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0264) |
| Минимальное снижение | 0,736 м/с на 31 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0264) |
| Качество | 13,2 на 37,7 км/ч | **оценка**: модель игры: поляра базы Icaro Laminar Easy 14 подобием по нагрузке на крыло (f = 1,0264); подобие качество не меняет — как у базы |
| Ветер на старте | плавающая поперечина, 12–15 м/с | **оценка**: класс — по поперечине, предел класса — со слов пилота (configs/wing_classes.json); подсказка меню игры, в физике не участвует |
| Эталонная масса пилота (для поляры) | 91 кг | **оценка**: модель игры: то же место в диапазоне, что у базы Icaro Laminar Easy 14 |

## Ссылки

- Конфиг крыла в игре: [configs/wings/bautek_astir.json](/configs/wings/bautek_astir.json)
- ТЗ на 3D-модель и сверка с паспортом: [раздел N17](/docs/research/glider_3d_tz.md#раздел-n17-bautek-astir-bautek_astir--новая-модель-приоритет-p2)
- Паспорта (у каждого числа — цитата и файл разбора): [wings_merged.json](/tools/research/data/wing_passports/wings_merged.json), как строился конфиг: [make_new_wings.py](/tools/research/data/wing_passports/make_new_wings.py)
- Данные карточек DHV — спасибо DHV: <a href="../../../#благодарности">благодарность на главной</a>
