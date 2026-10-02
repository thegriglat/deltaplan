---
type: "research"
status: "closed"
module: "wings"
updated: "2026-09-30"
summary: "Список моделей дельтапланов — Сгенерировано tools/research/data/wing_passports/consolidate.py (2026-09-30)."
related: []
conclusion: ""
data: ""
applied_in: ""
---
# Список моделей дельтапланов

Сгенерировано `tools/research/data/wing_passports/consolidate.py` (2026-09-30). Не править руками: добавить источник и перезапустить скрипт (см. «Как расширять»).

Всего: 203 записей (семейство+версия+размер), 78 семейств, 12 производителей; современных (сертификация ≥ 2015 или есть на сайте производителя): 35 семейств.

Столбцы: **Класс** — DHV (1, 1-2, 2, 2-3, 3, 3E) и прочие системы (HGMA/USHPA и т. п. как записаны в источнике). **Паспорт** — где есть: П = страница/PDF производителя, D = карточка DHV, Пл = плакат Wills Wing (Vms/Vd/Va/Vne), Пр = точки поляры. **3D** — есть размеры каркаса в мм (в `wings_geometry.json`). **Конфиг** — есть ли близкий `configs/wings/*.json` (по имени/прототипу, без сверки параметров).

Wölbklappen (управляемая кривизна: закрылки/VG-типа; в DHV-отчёте упомянуты) у: A.I.R. Atos VQ, A.I.R. Atos VR, A.I.R. Atos VRQ, A.I.R. Atos VRS, Aeros Phantom. Это жёсткие/особые аппараты, их размах (13–14,5 м) выходит за диапазон обычных 8–12,5 м — в `wings_merged.json` помечено `out_of_range`.

## Современные аппараты (сертификация ≥ 2015 или актуальны на сайте производителя)

| Производитель | Семейство | Класс | Размеры | Годы сертификации (DHV) | Статус | Паспорт | 3D | Конфиг |
|---|---|---|---|---|---|---|---|---|
| A.I.R. | Atos VQ | DHV 3E | 190 | 2007–2016 | актуальная (серт. ≥ 2015) | D | — | — |
| A.I.R. | Atos VR | DHV 3E; DHV 3 | 190 | 2005–2017 | актуальная (серт. ≥ 2015) | D | — | — |
| A.I.R. | Atos VRS | DHV 3E | 135, 190 | 2013–2016 | актуальная (серт. ≥ 2015) | D | — | — |
| Aeros | Combat C | DHV 3 | 12.4, 12.7, 13.5 | 2016–2021 | актуальная (серт. ≥ 2015) | D | — | combat.json |
| Aeros | Combat GT | DHV 3 | 12.4, 12.7, 12.8, 13.2, 13.5, 13.7, 14.2 | 2017 | актуальная (серт. ≥ 2015) | П+D | да | combat.json |
| Aeros | Fox | DHV 1 | 13 | 2016 | актуальная (серт. ≥ 2015) | D | — | — |
| Aeros | Target | DHV 1 | 21 | 2017 | актуальная (серт. ≥ 2015) | D | — | target.json |
| Airborne | F2 | HGMA/USHPA II Novice | 190 | — | актуальная (на сайте) | П | да | — |
| Airborne | XT | — | — | — | актуальная (на сайте) | П | да | — |
| Bautek | Astir | DHV 2 | — | — | актуальная (на сайте) | П | — | — |
| Bautek | BiCo | DHV 2 | — | 2005 | актуальная (на сайте) | П+D | — | — |
| Bautek | Fizz | DHV 3 | — | — | актуальная (на сайте) | П+D | да | — |
| Bautek | Kite | DHV 2 | — | 2006 | актуальная (на сайте) | П+D | — | — |
| Delta Flugschule Condor | Crex (3) | DHV 1 | 14.5 | 2016–2024 | актуальная (серт. ≥ 2015) | D | — | — |
| Delta Flugschule Condor | FLEX | DHV 1 | — | 2019 | актуальная (серт. ≥ 2015) | D | — | — |
| DesignProducts | Combat C AC | DHV 3 | 12.7, 13 | 2023–2024 | актуальная (серт. ≥ 2015) | D | — | — |
| DesignProducts | SHE 1 | DHV 3 | 12.7 | 2023 | актуальная (серт. ≥ 2015) | D | — | — |
| Ellipse | Sol'R | DHV 1 | — | 2018 | актуальная (серт. ≥ 2015) | D | — | — |
| Icaro | Alto | DHV 2-3; DHV 3 | S, M, L | 2022–2026 | актуальная (серт. ≥ 2015) | П+D | да | — |
| Icaro | Biplace | DHV 1 | — | — | актуальная (на сайте) | П | — | — |
| Icaro | Laminar (Z8, Zero 7, Zero 9) | DHV 3; класс на странице производителя 3 | 12.6, 13.2, 13.7, 14.1, 14.2, 14.8 | 2005–2013 | актуальная (на сайте) | П+D | да | laminar.json |
| Icaro | MastR | DHV 3 | S, M, L | 2009 | актуальная (на сайте) | П+D | — | — |
| Icaro | PiBi | DHV 1 | — | 2026 | актуальная (серт. ≥ 2015) | D | — | — |
| Icaro | Piuma (Trike) | DHV 1 | S, M, L, XL | 2019 | актуальная (серт. ≥ 2015) | П+D | да | — |
| Moyes | Gecko | DHV 3 | 155, 170 | 2016 | актуальная (серт. ≥ 2015) | П+D | да | — |
| Moyes | Litespeed RX | DHV 3 | 3, 3.5, 4, 5 | 2013–2015 | актуальная (серт. ≥ 2015) | П+D | да | sport.json |
| Moyes | Litesport | — | 3, 4 | — | актуальная (на сайте) | П | да | — |
| Moyes | Malibu (2) | DHV 1 | 166, 188 | 2009–2016 | актуальная (серт. ≥ 2015) | П+D | да | — |
| Wills Wing | Condor | — | 225, 330 | — | актуальная (на сайте) | П | — | — |
| Wills Wing | Falcon 4 | класс на странице производителя 2; HGMA/USHPA II Novice | 145, 170, 195 | — | актуальная (на сайте) | П+Пл | — | — |
| Wills Wing | Sport 3 | HGMA/USHPA III Intermediate; DHV 3 | 135, 155, 170 | 2025 | актуальная (серт. ≥ 2015) | П+D+Пл | — | — |
| Wills Wing | T2 | HGMA/USHPA IV Advanced | 144, 154 | — | актуальная (на сайте) | П+Пл | да | — |
| Wills Wing | T2C | DHV 3 | 136, 144, 154 | 2008–2013 | актуальная (на сайте) | П+D | да | — |
| Wills Wing | T3 | HGMA/USHPA IV Advanced | 136, 144, 154 | — | актуальная (на сайте) | П+Пл | — | — |
| Wills Wing | U2 | HGMA/USHPA III Intermediate; DHV 2-3; DHV 2 | 145, 160 | 2005–2013 | актуальная (на сайте) | П+D+Пл+Пр | — | — |

## Исторические

| Производитель | Семейство | Класс | Размеры | Годы сертификации (DHV) | Статус | Паспорт | 3D | Конфиг |
|---|---|---|---|---|---|---|---|---|
| A.I.R. | Atos VRQ | DHV 3E | — | — | историческая | D | — | — |
| Aeros | Combat L | DHV 3 | 12, 13, 14 | 2005–2008 | историческая | D | — | combat.json |
| Aeros | Discus | DHV 2; DHV 2-3 | 12, 13, 14, 15 | 2006–2013 | историческая | П+D | да | — |
| Aeros | Phantom | DHV 3E; DHV 3 | — | 2005 | историческая | D | — | — |
| Airborne | C4 | DHV 3 | 13.5, 14 | 2008 | историческая | D | — | — |
| Airborne | REV | DHV 3 | 13.5, 14.5 | — | историческая | D | — | — |
| Airborne | Sting 3 | DHV 2 | 154, 168, 175 | 2008–2009 | историческая | П+D | да | — |
| Delta Flugschule Condor | Lifter | DHV 1 | — | 2008 | историческая | D | — | — |
| Flugsport Skypoint | Crossover | DHV 2 | 14, 15 | — | историческая | D | — | — |
| Flugsport Skypoint | Funky | DHV 1 | 15, 17 | 2006 | историческая | D | — | — |
| Flugsport Skypoint | Space | DHV 1-2; DHV 1 | 14, 16 | 2007–2008 | историческая | D | — | — |
| Icaro | Easy 2 | DHV 2 | M, L | 2007 | историческая | D | — | — |
| Icaro | Orbiter | DHV 2-3; DHV 2 | 14, 16, S | 2005–2008 | историческая | D | — | — |
| Icaro | RX 2 BIP | DHV 1 | — | — | историческая | D | — | — |
| Moyes | Litespeed RS | DHV 3 | 3.5, 4 | 2007 | историческая | D | — | sport.json |
| Moyes | Litespeed S | DHV 3 | 3.5, 4, 4.5, 5 | 2005 | историческая | П+D | да | sport.json |
| Seedwings | Skyrunner XR | DHV 2-3 | — | 2013 | историческая | D | — | — |
| Seedwings | Spyder | DHV 2 | 12.5 | 2005 | историческая | D | — | — |
| Wills Wing | Attack Duck | — | 160, 180 | — | историческая | П | — | — |
| Wills Wing | Cross Country | HGMA/USHPA IV Advanced | 132, 142, 155 | — | историческая | П+Пл | — | — |
| Wills Wing | Duck | — | 130, 160, 180, 200 | — | историческая | П | — | — |
| Wills Wing | Eagle | HGMA/USHPA II Novice | 145, 164, 180 | — | историческая | П+Пл+Пр | — | — |
| Wills Wing | Falcon | HGMA/USHPA II Novice | 140, 170, 195, 225 | — | историческая | П+Пл+Пр | — | training.json |
| Wills Wing | Falcon 2 | HGMA/USHPA II Novice | 140, 170, 195, 225 | — | историческая | П+Пл | — | — |
| Wills Wing | Falcon 3 | HGMA/USHPA II Novice | 145, 170, 195 | — | историческая | П+Пл | — | — |
| Wills Wing | Fusion | HGMA/USHPA IV Advanced | 141, 150 | — | историческая | П+Пл+Пр | — | — |
| Wills Wing | HP | — | 170 | — | историческая | П | — | — |
| Wills Wing | HP AT | HGMA/USHPA IV Advanced | 145, 158 | — | историческая | П+Пл | — | — |
| Wills Wing | HP II | — | 170 | — | историческая | П | — | — |
| Wills Wing | Harrier | — | 147, 177, 187 | — | историческая | П | — | — |
| Wills Wing | Harrier II | — | 147, 177, 187 | — | историческая | П | — | — |
| Wills Wing | RamAir | HGMA/USHPA IV Advanced | 146, 154 | — | историческая | П+Пл | — | — |
| Wills Wing | Raven | — | 149, 179, 209, 229 | — | историческая | П | — | — |
| Wills Wing | Skyhawk | HGMA/USHPA II Novice | 168, 188 | — | историческая | П+Пл | — | — |
| Wills Wing | Spectrum | HGMA/USHPA II Novice | 144, 165 | — | историческая | П+Пл | — | — |
| Wills Wing | Sport | HGMA/USHPA III Intermediate | 150, 167, 180 | — | историческая | П | — | — |
| Wills Wing | Sport 2 | HGMA/USHPA III Intermediate; DHV 1-2; DHV 2 | 135, 155, 175 | 2008–2013 | историческая | D+Пл+Пр | — | — |
| Wills Wing | Sport AT | HGMA/USHPA III Intermediate | 150, 167, 180 | — | историческая | П | — | — |
| Wills Wing | Sportster | HGMA/USHPA III Intermediate | 148 | — | историческая | П | — | — |
| Wills Wing | Super Sport | HGMA/USHPA III Intermediate | 143, 153, 163 | — | историческая | П+Пл+Пр | — | — |
| Wills Wing | T2/T2C | HGMA/USHPA IV Advanced | 136, 144, 154 | — | историческая | Пл | — | — |
| Wills Wing | Talon | HGMA/USHPA IV Advanced | 140, 150, 160 | — | историческая | П+Пл+Пр | — | — |
| Wills Wing | Ultra Sport | HGMA/USHPA III Intermediate | 135, 147, 166 | — | историческая | П+Пл+Пр | — | — |

## Как расширять

1. Добавить источник: `fetch_makers.py` / `fetch_pdfs.py` / `fetch_dhv.py` кладут сырьё в `raw/`; разбор (Haiku, промпт `haiku_prompt.md`, схема в `parse.py`) даёт JSON в `out/haiku/` (страницы и PDF производителей) или `out/haiku_dhv/` (карточки DHV, пачки).
2. Запустить `python3 consolidate.py` в `tools/research/data/wing_passports/` — пересоберёт `wings_merged.json/csv`, `wings_geometry.json`, `polars_points.json`, эту страницу и `consolidate_stats.json`.
3. Новое семейство с нетривиальным названием: добавить правило в `norm_model()` (иначе оно попадёт в список «как есть», а размер определится по первому числу).
4. Новый производитель: строка в `norm_mfr()`.

## Кандидаты, упомянутые в источниках, но без паспорта

Список ниже собирается скриптом из `out/text/*` (если он есть локально) — имена моделей, встречающиеся рядом с названиями производителей, но без записей в наборе.

- **Airborne**: Edge (51), Tandem (17), Clip (3)
- **Wills Wing**: Alpha (7)
- **Moyes**: Sting (38), Sonic (8), Mars (7), Xtralite (2)
- **Icaro**: Mini (8)
- **Aeros**: Bravo (2)
- **A.I.R.**: Zephir (2)

DHV Geräteportal: в индексе 524 дельтапланов (1979–2026), карточки скачаны и разобраны для 107; сертификаты ≥ 2015 без разобранной карточки: 0 (все современные сертификаты DHV в наборе).
Остальные ~400 карточек — старые модели 1979–2013 (не скачивались). Расширить: `fetch_dhv.py` с большим лимитом, затем разбор пачек в `out/haiku_dhv/`.

Конфиги игры без записи в наборе (прототипы, которых нет в источниках паспортов): apogee.json (wing_apogee), atlas.json (wing_atlas), magic.json (wing_airwave_magic), slavutich_ut.json (wing_slavutich_ut).
