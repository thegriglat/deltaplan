# ТЗ на 3D-модели крыльев по паспортам (DHV, производители)

Сгенерировано `tools/research/data/wing_passports/make_3d_tz.py` из паспортного набора (`tools/research/data/wing_passports/`, 203 записи, 78 семейств), ручной части `tz_curated.py` и `tools/blender/glider_params.json` (2026-10-01). Числа в разделах — паспортные с указанием источника; что не указано числом, в источниках отсутствует (закрутка, кривизна профиля, форма паруса, высота кингпоста, расцветка) — **не выдумывать, оставлять значения базы**.

Как пользоваться: **каждый раздел самодостаточен** — исполнитель читает только свой (разделы `E…` — существующие модели, `N…` — новые) и его «Как делать и проверять». Единый шаблон раздела: модель, класс, конструкция, что есть сейчас, что менять/задать (таблица «параметр — значение — откуда»), паспортные данные, источники, открытые вопросы.

## Общие сведения

- **3D-модели** генерируются Blender-скриптом (`tools/blender/build_gliders.py`, параметры — `tools/blender/glider_params.json`); ручной правки `.glb` нет. Подробности, контракт имён и бюджеты — `docs/models.md`. Существующие базы: `training` (учебное однообшивочное мачтовое, 122°, 8 лат), `target` (то же с колёсами), `laminar` (мачтовое двухобшивочное, 127°, 13 лат), `magic` (мачтовое 1980-х, 60 %), `sport` (безмачтовое, 132°, 14 лат), `combat` (безмачтовое, 130°, 16 лат); советские — `slavutich_ut`, `atlas`, `apogee`.
- **Новая модель = новая запись** `wings.<id>` (копия записи базы + значения из раздела), новый `glider_<id>.glb` и (отдельной задачей, не этой) конфиг `configs/wings/<id>.json`: тест `tests/flight/test_wings.gd` требует, чтобы `visual.visual_model` конфига был `res://assets/models/glider_<id>.glb`. Каталог крыльев меню строится по `configs/wings/*.json`, поэтому 3D-модель без конфига в игре не появится.
- **Планформа.** Парус описывается: размах `b` (из конфига), угол носа, хорда у корня `root` и на конце `tip` (закон `c(a) = tip + (root − tip)(1 − a^0,85)`, `a` — доля полуразмаха), передняя кромка прямая. Площадь в плане `S = b·(k_r·root + k_t·tip)`; `k_r ≈ 0,459`, `k_t ≈ 0,529` с учётом скругления законцовки (без скругления 0,4595 и 0,5405; точные значения — `wings3d_geometry.py`). Из паспорта известны `b`, `S`, угол носа; хорды корня и конца по ним не определяются однозначно, поэтому **форма хорд берётся от базы** (отношение `tip/root`), масштаб — под паспортные `b` и `S`. Вынос носа вперёд от подвеса: `nose_forward_m` = положение ЦТ от носа киля, если оно есть в паспорте (Moyes), иначе 0,568·`root` (как у всех существующих моделей).
- **Число лат.** В паспортах «Anzahl Latten»/«number of battens» — обычно верхних лат всего; на сторону — половина (у нечётных — округлять, нижние короткие латы `short_battens` не учитываются). Значения вне 9…40 считаются ошибкой разбора и отбрасываются.
- **Двойная поверхность.** `double_surface_pct` из DHV/страниц — процент; в модели: `double_surface` = true при ≥ 50 %, `lower_cover` ≈ процент/100 (допуск ±0,1 по фото производителя).
- **Угол носа.** Часто диапазон по положению VG (например 127–132°): берётся середина диапазона.
- **Надёжность данных.** Числа разобраны моделью Haiku из страниц/PDF/карточек DHV; у каждого значения есть цитата и файл (`wings_merged.json`). При расхождении источников (> 3 %) приоритет: DHV > PDF производителя > страница производителя > архив. DHV «Vne» (испытанная) обычно ниже заявленной производителем; «Startgewicht» DHV — испытательный диапазон, не рекомендованный диапазон пилота. Записи вне физического диапазона (размах вне 8–12,5 м, площадь вне 8–22 м²) помечены в разделе и для размеров не используются без перепроверки.
- **Тип конструкции** (мачтовое/безмачтовое) брался из выборки по открытым страницам (`tools/research/data/wing_passports/out/construction/batch_*.json`, Haiku); принимается только при цитате, прямо называющей мачту/безмачтовость, иначе — предположение координатора с пометкой. Неверные отметки выборки (например T2/T2C/T3 названы «kingpost» без подтверждающей цитаты) отброшены.
- **Физика не в этом ТЗ.** Поляры, скорости, сваливание — отдельная задача (`docs/research/wings_config_sources.md`): числа L/D из заявок производителей для конфигов не использовать.

## Сводка разделов

| Раздел | Модель | id | Класс (кратко) | Конструкция | База | Приоритет |
|---|---|---|---|---|---|---|
| E1 | Wills Wing Falcon 4 170 | `training` | учебное однообшивочное мачтовое | мачтовое | — | существующая |
| E2 | Aeros Target 16 | `target` | учебное (DHV 1) | мачтовое | — | существующая |
| E3 | Moyes Litespeed RS 4 | `sport` | спортивное безмачтовое (DHV 3) | безмачтовое | — | существующая |
| E4 | Aeros Combat GT 13.2 | `combat` | соревновательное безмачтовое (DHV 3) | безмачтовое | — | существующая |
| E5 | Icaro Laminar Easy 14 (мачтовый) | `laminar` | среднее/спортивное мачтовое двухобшивочное (DHV 2 у Easy 2; 2-3 у Orbiter) | мачтовое | — | существующая |
| E6 | Airwave Magic IV 166 | `magic` | соревновательное мачтовое 1980-х (DS 60 % | мачтовое | — | существующая |
| E7 | «Атлас» (копия La Mouette Atlas 16) | `atlas` | советское учебное однообшивочное мачтовое | мачтовое | — | существующая |
| E8 | Славутич-УТ | `slavutich_ut` | советское учебное однообшивочное мачтовое | мачтовое | — | существующая |
| E9 | «Апогей» (В. В. Мысенко) | `apogee` | советское мачтовое двухобшивочное 80 % | мачтовое | — | существующая |
| N1 | Icaro Piuma | `icaro_piuma` | рекреационное/учебное (DHV 1) | мачтовое | `training` | P1 |
| N2 | Moyes Malibu 2 | `moyes_malibu2` | рекреационное/учебное (DHV 1) | мачтовое | `training` | P1 |
| N3 | Airborne F2 | `air_f2` | учебное (HGMA/USHPA II Novice) | мачтовое (предп.) | `training` | P1 |
| N4 | Aeros Fox | `aeros_fox` | учебное (DHV 1) | мачтовое | `target` | P1 |
| N5 | Delta Flugschule Condor Crex 3 | `condor_crex3` | учебное (DHV 1) | мачтовое (предп.) | `training` | P2 |
| N6 | Delta Flugschule Condor FLEX / Lifter | `condor_flex` | учебное (DHV 1) | мачтовое (предп.) | `training` | P2 |
| N7 | Flugsport Skypoint Funky | `fs_funky` | учебное (DHV 1) | мачтовое | `training` | P2 |
| N8 | Flugsport Skypoint Space | `fs_space` | учебное/начальное (DHV 1-2) | мачтовое (предп.) | `training` | P2 |
| N9 | Wills Wing Eagle | `ww_eagle` | начальное–среднее (USHPA II Novice) | мачтовое | `magic` | P2 |
| N10 | Wills Wing Sport 3 | `ww_sport3` | среднее (USHPA III Intermediate; DHV 3 по сертификату 2025) | мачтовое | `laminar` | P1 |
| N11 | Wills Wing U2 | `ww_u2` | среднее–спортивное (USHPA III; DHV 2-3) | мачтовое | `laminar` | P1 |
| N12 | Aeros Discus | `aeros_discus` | среднее (DHV 2; 2-3 у размера 15) | мачтовое | `laminar` | P1 |
| N13 | Airborne Sting 3 | `air_sting3` | среднее (DHV 2) | мачтовое | `laminar` | P1 |
| N14 | Icaro Alto | `icaro_alto` | среднее (DHV 2-3) | мачтовое | `laminar` | P1 |
| N15 | Icaro MastR | `icaro_mastr` | спортивное (DHV 3) | безмачтовое | `combat` | P1 |
| N16 | Bautek Kite | `bautek_kite` | среднее (DHV 2) | мачтовое | `laminar` | P2 |
| N17 | Bautek Astir | `bautek_astir` | среднее (DHV 2) | ? | `laminar` | P2 |
| N18 | Flugsport Skypoint Crossover | `fs_crossover` | среднее (DHV 2) | мачтовое (предп.) | `laminar` | P2 |
| N19 | Seedwings Spyder | `seed_spyder` | среднее (DHV 2) | безмачтовое | `sport` | P2 |
| N20 | Moyes Gecko | `moyes_gecko` | среднее/спортивное (DHV 3 по сертификату 2016) | мачтовое | `laminar` | P1 |
| N21 | Wills Wing Sport 2 | `ww_sport2` | среднее (USHPA III; DHV 2) | мачтовое | `laminar` | P2 |
| N22 | Wills Wing Super Sport | `ww_super_sport` | среднее (USHPA III) | ? | `magic` | P2 |
| N23 | Wills Wing Ultra Sport | `ww_ultra_sport` | среднее (USHPA III) | мачтовое | `magic` | P2 |
| N24 | Wills Wing Spectrum | `ww_spectrum` | начальное (USHPA II Novice) | ? | `training` | P2 |
| N25 | Wills Wing T2 / T2C | `ww_t2c` | соревновательное безмачтовое (DHV 3; USHPA IV Advanced) | безмачтовое (предп.) | `sport` | P1 |
| N26 | Wills Wing T3 | `ww_t3` | соревновательное безмачтовое (USHPA IV Advanced) | безмачтовое (предп.) | `sport` | P1 |
| N27 | Moyes Litespeed RX | `moyes_litespeed_rx` | соревновательное безмачтовое (DHV 3) | безмачтовое | `sport` | P1 |
| N28 | Moyes Litespeed S | `moyes_litespeed_s` | спортивное безмачтовое (DHV 3) | безмачтовое | `sport` | P2 |
| N29 | Moyes Litesport | `moyes_litesport` | средне-спортивное (класс на странице не указан) | мачтовое | `laminar` | P1 |
| N30 | Aeros Combat C (и DesignProducts Combat C AC) | `aeros_combat_c` | соревновательное безмачтовое (DHV 3) | безмачтовое | `combat` | P1 |
| N31 | Aeros Combat L | `aeros_combat_l` | соревновательное безмачтовое (DHV 3) | безмачтовое | `combat` | P2 |
| N32 | Icaro Laminar (Zero 9 / Zero 7 / Z8) | `icaro_laminar_z9` | соревновательное безмачтовое (DHV 3) | безмачтовое | `combat` | P1 |
| N33 | Bautek Fizz | `bautek_fizz` | среднее/спортивное (DHV 3) | мачтовое | `laminar` | P1 |
| N34 | Airborne C4 | `air_c4` | соревновательное безмачтовое (DHV 3) | безмачтовое | `combat` | P2 |
| N35 | Airborne REV | `air_rev` | соревновательное безмачтовое (DHV 3) | безмачтовое | `combat` | P2 |
| N36 | DesignProducts SHE 1 | `dp_she1` | соревновательное безмачтовое (DHV 3) | безмачтовое (предп.) | `combat` | P2 |
| N37 | Seedwings Skyrunner XR | `seed_skyrunner_xr` | среднее (DHV 2-3) | мачтовое | `laminar` | P2 |
| N38 | Wills Wing Fusion | `ww_fusion` | продвинутое (USHPA IV Advanced) | безмачтовое | `sport` | P2 |
| N39 | Wills Wing Talon | `ww_talon` | продвинутое (USHPA IV Advanced) | безмачтовое | `sport` | P2 |
| N40 | Wills Wing Cross Country | `ww_cross_country` | продвинутое (USHPA IV Advanced) | ? | `magic` | P2 |


## Не включены в ТЗ

| Семейства | Почему |
|---|---|
| A.I.R. Atos VQ / VR / VRS / VRQ, Aeros Phantom | жёсткие крылья (Wölbklappen), размах 12–14,5 м — вне рамок модели «гибкое крыло» (docs/plan/wings_lineup.md §1.5) |
| Icaro Biplace, Icaro PiBi, Icaro RX 2 BIP, Aeros Target 21, Wills Wing Condor (225/330), Bautek BiCo | тандемы/учебные двухместные (нагрузка 120–240 кг) — в игре один пилот |
| Icaro Piuma Trike, Airborne XT | тележечные (trike/мотор) — не свободный полёт |
| Ellipse Sol'R | сверхлёгкий (Vne 55 км/ч), данных для 3D нет |
| Icaro Easy 2 / Orbiter | используются как аналог существующего `laminar` (раздел E5), отдельной модели не делаем |
| Wills Wing Falcon, Falcon 2, Falcon 3, Skyhawk, Duck, Attack Duck, Harrier, Harrier II, Raven, HP, HP II, HP AT, Sport, Sport AT, Sportster, RamAir | архивные WW: в паспорте только площадь и плакат (без размаха, угла носа, лат), не отличаются от уже имеющихся баз; Falcon 2/3 — предыдущие поколения существующего `training` |

---

## Раздел E1. Wills Wing Falcon 4 170 (`training`) — существующая модель

- **Модель:** Wills Wing Falcon 4 170; файл `assets/models/glider_training.glb`, параметры — `tools/blender/glider_params.json` → `wings.training`, конфиг — `configs/wings/training.json`.
- **Класс:** учебное однообшивочное мачтовое, USHPA II Novice (на странице производителя класс 2; HGMA 2015). Группа игры: `trainer`.
- **Что есть сейчас:** размах 9,3 м, площадь в конфиге 15,8 м², в плане по модели 15,3 м²; угол носа 122°, хорда у корня/на конце 2,55/0,9 м, лат на сторону 8, двойная поверхность нет (нижняя обшивка на 0,14 хорды), кингпост 1,25 м, подвес: нос на 1,45 м впереди; двугранность 1,5°, закрутка 14°.
- **Конструкция:** мачтовое.

### Что менять

| Параметр | Сейчас | Стало | Основание |
|---|---|---|---|
| `tip_chord_m` | 0,90 | 1,00 | площадь в плане по модели 15,3 м² против паспортных 15,79 м² (допуск ±1,5 %); хорду у корня не менять |

Без изменений, подтверждено паспортом: размах 9,3 м ≈ паспорт 9,33 м.

- Геометрию менять минимально: паспорт подтверждает размах 9,33 м, площадь 15,79 м², удлинение 5,5, массу 22,2 кг; у 3D-модели сейчас площадь в плане 15,3 м² (на 3 % меньше) — подогнать хорды (см. «Что менять»).
- Числа по углу носа, числу латов, высоте кингпоста, закрутке, форме паруса в паспортах Falcon 4 отсутствуют — оставить значения модели, не менять «на глаз».

### Паспортные данные

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Falcon 4 170 | 15,79 | 9,33 | 5,5 | 22,2 | 64–100 | — | 77 | — | — |
| Falcon 4 145 | 13,47 | 8,53 | 5,4 | 20,4 | 54–86 | — | 77 | — | — |
| Falcon 4 195 | 18,12 | 10,06 | 5,6 | 24,5 | 79–125 | — | 77 | — | — |

### Источники

- https://www.willswing.com/hang-gliders/falcon-4/
- https://www.willswing.com/hang-glider-placard-specifications/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Falcon 4||170`, `Wills Wing|Falcon 4||145`, `Wills Wing|Falcon 4||195`).
- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.

### Открытые вопросы

- Данных о проценте нижней обшивки у Falcon 4 в паспорте нет (в конфиге 0 %, в модели `lower_cover` 0,14).
- Высота кингпоста и положение подвеса относительно носа у Falcon 4 в открытых источниках не найдены.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел E2. Aeros Target 16 (`target`) — существующая модель

- **Модель:** Aeros Target 16; файл `assets/models/glider_target.glb`, параметры — `tools/blender/glider_params.json` → `wings.target`, конфиг — `configs/wings/target.json`.
- **Класс:** учебное (DHV 1), мачтовое, с колёсами на базовой штанге. Группа игры: `trainer`.
- **Что есть сейчас:** размах 9,6 м, площадь в конфиге 16,2 м², в плане по модели 16,2 м²; угол носа 120°, хорда у корня/на конце 2,6/0,93 м, лат на сторону 8, двойная поверхность нет (нижняя обшивка на 0,14 хорды), кингпост 1,25 м, подвес: нос на 1,47 м впереди; двугранность 1,5°, закрутка 14°.
- **Конструкция:** мачтовое.

### Что менять

Числовых правок нет.

Без изменений, подтверждено паспортом: площадь в плане 16,2 м² ≈ паспорт 16,2 м²; размах 9,6 м ≈ паспорт 9,6 м; число лат 8 на сторону ≈ паспорт (15 всего); доля двойной поверхности по паспорту 25 % (в конфиге 0 %: см. правки json).

- Прямого паспорта Target 16 в наборе нет. Ближайшие записи: Aeros Fox (DHV 1, 2016) 16,2 м² / 9,6 м — те же площадь и размах, что у Target 16 в конфиге; Aeros Target 21 (тандем, DHV 1) — другая модель. Связь Fox↔Target источниками не подтверждена (см. `out/construction/batch_b.json`), поэтому 3D-модель Target 16 менять только там, где Fox и Target совпадают по размерам.
- Число латов у Fox 15 (всего), у Fox 13 — 13: у Target 16 сейчас 8 на сторону (16) — в допуске, не менять.

### Паспортные данные

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Fox | 16,2 | 9,6 | — | 25,2 | — | 25 | 75 | — | 15 |
| Target 21 | 20,5 | 10,8 | — | 36,5 | — | 20 | 80 | — | 17 |
| Fox 13 | 13,4 | 8,6 | — | 20,6 | — | 30 | 70 | — | 13 |

Размеры каркаса/прочее (из `wings_geometry.json`):

- `battens` = 15  — «15 / 0»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_00)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_07)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_02)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_09)
- Номера DHV-сертификатов: DHV 01-0457-10, DHV 01-0494-17, DHV 01-0484-16
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Aeros|Fox||`, `Aeros|Target||21`, `Aeros|Fox||13`).
- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.

### Открытые вопросы

- Доля двойной поверхности: DHV даёт 25 % (Fox) и 20 % (Target 21 тандем), конфиг и модель — однообшивочное (0 %). Не менять молча: для Target 16 1995 г. данных нет.
- Совпадение Fox 16 с Target 16 по размерам — случайность или преемственность (Fox заменил Target?).

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел E3. Moyes Litespeed RS 4 (`sport`) — существующая модель

- **Модель:** Moyes Litespeed RS 4; файл `assets/models/glider_sport.glb`, параметры — `tools/blender/glider_params.json` → `wings.sport`, конфиг — `configs/wings/sport.json`.
- **Класс:** спортивное безмачтовое (DHV 3), VG (в игре VG нет). Группа игры: `topless`.
- **Что есть сейчас:** размах 10,4 м, площадь в конфиге 14,1 м², в плане по модели 14 м²; угол носа 132°, хорда у корня/на конце 2,3/0,55 м, лат на сторону 14, двойная поверхность да (нижняя обшивка на 0,7 хорды), кингпост 0 м, подвес: нос на 1,3 м впереди; двугранность -2°, закрутка 10°.
- **Конструкция:** безмачтовое (топлесс).

### Что менять

| Параметр | Сейчас | Стало | Основание |
|---|---|---|---|
| `battens_per_side` | 14 | 11 | DHV и Moyes (RS/RX/S): 23 верхних лат всего → 11 на сторону + 1 у киля (проверить) |
| `nose_forward_m` | 1,3 | 1,35 | паспорт: ЦТ 1343–1353 мм от носа киля (RX 4 — 1353, S 4 — 1353) |
| `nose_angle_deg` | 132 | 128 | паспорт: RX 125–130°, S 130–132°, по lineup для RS 4 125–130° — середина; было 132 |

Без изменений, подтверждено паспортом: площадь в плане 14 м² ≈ паспорт 14,1 м²; размах 10,4 м ≈ паспорт 10,4 м; доля двойной поверхности по паспорту 92 % (в конфиге 92 %: см. правки json).

- Для RS 4 паспорт = карточка DHV (01-…); технические страницы — у Litespeed RX и S (тот же корпус/ряд): положение ЦТ от носа киля 1353 мм (RX 4 и S 4), угол носа 125–130° (RX) / 130–132° (S), поперечина: «Undersurface 6» нижних лат.
- Число латов: по DHV и страницам Moyes «Mainsail 23» (верхние, всего) — около 11–12 на сторону. В модели сейчас 14 на сторону — завышено.

### Паспортные данные

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Litespeed RS 4 | 14,1 | 10,4 | — | 34,4 | — | 92 | — | — | 23 |
| Litespeed RX 4 | 13,9 | 10,27 | 7,6 | 34,2 | 75–115 | 92 | 90 | 125–130 | 23 |
| Litespeed RS 3.5 | 13,7 | 10,3 | — | 34,4 | — | 92 | — | — | 23 |
| Litespeed S 4 | 13,7 | 10 | 7,3 | 36 | 68–109 | 92 | 90 | 130 | 23 |

Размеры каркаса/прочее (из `wings_geometry.json`):

- `battens` = 23  — «23 / 6»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_05)
- https://www.moyes.com.au/products/hang-gliders/litespeed-rx/specifications
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_01)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_02)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_09)
- https://www.delta-club-82.com/bible/manuels/litespeed-S.pdf
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_03)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_10)
- Номера DHV-сертификатов: DHV 01-0427-07, DHV 01-0468-13, DHV 01-0481-15, DHV 01-0426-07, DHV 01-0403-05
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Moyes|Litespeed RS||4`, `Moyes|Litespeed RX||4`, `Moyes|Litespeed RS||3.5`, `Moyes|Litespeed S||4`).
- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.

### Открытые вопросы

- Число 23 — нечётное: вероятно 11 + 11 + 1 (у киля); проверить по фото/руководству, либо принять 11 на сторону.
- Диаметр киля 42 мм (Litespeed S) — у других Moyes не подтверждён; 3D-модель делает киль по общему правилу.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел E4. Aeros Combat GT 13.2 (`combat`) — существующая модель

- **Модель:** Aeros Combat GT 13.2; файл `assets/models/glider_combat.glb`, параметры — `tools/blender/glider_params.json` → `wings.combat`, конфиг — `configs/wings/combat.json`.
- **Класс:** соревновательное безмачтовое (DHV 3), VG (в игре VG нет). Группа игры: `topless`.
- **Что есть сейчас:** размах 10,35 м, площадь в конфиге 13,2 м², в плане по модели 13,2 м²; угол носа 130°, хорда у корня/на конце 2,2/0,5 м, лат на сторону 16, двойная поверхность да (нижняя обшивка на 0,95 хорды), кингпост 0 м, подвес: нос на 1,25 м впереди; двугранность -2°, закрутка 9°.
- **Конструкция:** безмачтовое (топлесс).

### Что менять

| Параметр | Сейчас | Стало | Основание |
|---|---|---|---|
| `battens_per_side` | 16 | 12 | Aeros: «Number of upper sail battens 24» → 12 на сторону (DHV: 26 всего — 13) |

Без изменений, подтверждено паспортом: площадь в плане 13,2 м² ≈ паспорт 13,2 м²; размах 10,35 м ≈ паспорт 10,35 м; угол носа 130° в паспортном диапазоне 129–131°; доля двойной поверхности по паспорту 90 % (в конфиге 90 %: см. правки json).

- Число латов: Aeros — «Number of upper sail battens 24», DHV — 26 (всего) → 12–13 на сторону. В модели сейчас 16 на сторону — завышено на 3–4.
- Доля двойной поверхности в DHV — 90 % у всех GT; в конфиге было 95 % — исправлено в `configs/wings/combat.json`.

### Паспортные данные

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Combat GT 13.2 | 13,2 | 10,35 | 8,05 | 36,3 | 70–110 | 90 | 90 | 129–131 | 26 |
| Combat GT 12.7 | 12,7 | 10,3 | 8,4 | 36 | 80–100 | 90 | 90 | 129–131 | 24 |
| Combat GT 13.5 | 13,5 | 10,7 | 8,5 | 38,2 | 90–110 | 90 | 90 | 129–131 | 26 |

Размеры каркаса/прочее (из `wings_geometry.json`):

- `nose_angle` = 129 ° — «Nose angle, ° / 129-131»
- `battens` = 24  — «Number of upper sail battens / 24»
- `battens` = 26  — «26 / 6»

### Источники

- https://aeros.com.ua/combat_gt
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_00)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_07)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_02)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_10)
- Номера DHV-сертификатов: DHV 01-0454-10, DHV 01-0493-17, DHV 01-0458-11
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Aeros|Combat GT||13.2`, `Aeros|Combat GT||12.7`, `Aeros|Combat GT||13.5`).
- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.

### Открытые вопросы

- Масса: Aeros 35 кг (конфиг), DHV 36,3 кг — на модель не влияет.
- Абсолютная L/D (16 на 50 км/ч в конфиге) — не из паспорта, см. отчёт (у класса T2C по LK8000 13,6); к 3D-модели не относится.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел E5. Icaro Laminar Easy 14 (мачтовый) (`laminar`) — существующая модель

- **Модель:** Icaro Laminar Easy 14 (мачтовый); файл `assets/models/glider_laminar.glb`, параметры — `tools/blender/glider_params.json` → `wings.laminar`, конфиг — `configs/wings/laminar.json`.
- **Класс:** среднее/спортивное мачтовое двухобшивочное (DHV 2 у Easy 2; 2-3 у Orbiter), VG. Группа игры: `kingpost`.
- **Что есть сейчас:** размах 10,3 м, площадь в конфиге 14,5 м², в плане по модели 14,5 м²; угол носа 127°, хорда у корня/на конце 2,35/0,62 м, лат на сторону 13, двойная поверхность да (нижняя обшивка на 0,8 хорды), кингпост 1,15 м, подвес: нос на 1,34 м впереди; двугранность -1°, закрутка 11°.
- **Конструкция:** мачтовое.

### Что менять

| Параметр | Сейчас | Стало | Основание |
|---|---|---|---|
| `battens_per_side` | 13 | 9 | аналог Easy 2 M / Orbiter 14 (DHV: 18 лат всего), а не топлесс-Laminar (22–26 верхних) |

Без изменений, подтверждено паспортом: размах и площадь не правятся: тождество прототипа с аналогом в паспорте не доказано; доля двойной поверхности по паспорту 85 % (в конфиге 85 %: см. правки json).

- Точного паспорта «Laminar Easy 14» в наборе нет. Ближайшая запись — Icaro Easy 2 M / Orbiter 14 (14,45 м², 10,35 м, 85 % двойной, DHV 2, 18 лат) — почти совпадает с конфигом (14,5 м², 10,3 м). Прямая связь «Laminar Easy» ↔ «Easy 2/Orbiter» — в `out/construction/batch_c.json`.
- Модель сейчас — 13 лат на сторону (как у топлесс-Laminar 13.7/14.1): для мачтового Easy 2 M по DHV 18 лат всего, т. е. 9 на сторону.

### Паспортные данные

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Easy 2 M | 14,45 | 10,35 | — | 30,5 | — | 85 | — | — | 18 |
| Orbiter 14 | 14,45 | 10,35 | — | 30,5 | — | 85 | 90 | — | 18 |
| Laminar 14.1 | 14,1 | 10,7 | 7,72 | 33,6 | 92–102 | 96 | 90 | 134 | 26 |
| MastR L | 14,8 | 10,4 | 7,38 | 31,5 | 85–110 | 94 | 90 | 131 | 22 |

Размеры каркаса/прочее (из `wings_geometry.json`):

- `battens` = 18  — «18 / 4»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_05)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_04)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- https://www.icaro2000.com/Products/Manuals/Laminar%202011-3-En.docx.pdf
- https://www.icaro2000.com/Products/Hanggliders/Laminar/Laminar 2022 Imperial data.pdf
- https://www.icaro2000.com/Products/Hanggliders/Laminar/Laminar 2022 Metric data.pdf
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_01)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- https://www.icaro2000.com/ (страница Icaro, файл разбора icaro__mastr)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- Номера DHV-сертификатов: DHV 01-0424-07, DHV 01-0412-05, DHV 01-0476-13, DHV 01-0443-09
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Icaro|Easy 2||M`, `Icaro|Orbiter||14`, `Icaro|Laminar||14.1`, `Icaro|MastR||L`).
- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.

### Открытые вопросы

- Тождество «Laminar Easy 14» = «Easy 2 M / Orbiter 14» не доказано — поэтому масса и % двойной в конфиге взяты по аналогу с пометкой.
- Угол носа: 127° (Wikipedia) — в паспортах Easy 2/Orbiter нет; оставить.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел E6. Airwave Magic IV 166 (`magic`) — существующая модель

- **Модель:** Airwave Magic IV 166; файл `assets/models/glider_magic.glb`, параметры — `tools/blender/glider_params.json` → `wings.magic`, конфиг — `configs/wings/magic.json`.
- **Класс:** соревновательное мачтовое 1980-х (DS 60 %, VG). Группа игры: `kingpost`.
- **Что есть сейчас:** размах 10,26 м, площадь в конфиге 15,4 м², в плане по модели 15,4 м²; угол носа 124°, хорда у корня/на конце 2,39/0,75 м, лат на сторону 11, двойная поверхность да (нижняя обшивка на 0,6 хорды), кингпост 1,2 м, подвес: нос на 1,36 м впереди; двугранность 0°, закрутка 13°.
- **Конструкция:** мачтовое.

### Что менять

Числовых правок нет.

Без изменений, подтверждено паспортом: паспортов этого семейства в наборе нет — числа не меняются.

- В наборе паспортов этого семейства нет: 3D-модель не менять. Источники геометрии — прежние (docs/plan/wings_lineup.md §1.3: 15,4 м², 10,26 м, корневая хорда 2,39 м).

### Источники

- Прежние источники модели — `docs/plan/wings_lineup.md`, `docs/research/wing_sources.md`; паспортов в наборе нет.
- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.

### Открытые вопросы

- Если понадобится уточнение — искать архивные спецификации Airwave (в текущих источниках нет).

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел E7. «Атлас» (копия La Mouette Atlas 16) (`atlas`) — существующая модель

- **Модель:** «Атлас» (копия La Mouette Atlas 16); файл `assets/models/glider_atlas.glb`, параметры — `tools/blender/glider_params.json` → `wings.atlas`, конфиг — `configs/wings/atlas.json`.
- **Класс:** советское учебное однообшивочное мачтовое, 1979–1980-е. Группа игры: `soviet`.
- **Что есть сейчас:** размах 9,8 м, площадь в конфиге 15,5 м², в плане по модели 15,5 м²; угол носа 120°, хорда у корня/на конце 2,7/0,63 м, лат на сторону 8, двойная поверхность нет (нижняя обшивка на 0,15 хорды), кингпост 1,25 м, подвес: нос на 1,52 м впереди; двугранность 2°, закрутка 16°.
- **Конструкция:** мачтовое.

### Что менять

Числовых правок нет.

Без изменений, подтверждено паспортом: паспортов этого семейства в наборе нет — числа не меняются.

- Паспортов нет (La Mouette в наборе отсутствует): 3D-модель не менять. Данные — `docs/plan/atlas_wing.md`, `docs/plan/wings_lineup.md` §1.2.

### Источники

- Прежние источники модели — `docs/plan/wings_lineup.md`, `docs/research/wing_sources.md`; паспортов в наборе нет.
- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.

### Открытые вопросы

- нет

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел E8. Славутич-УТ (`slavutich_ut`) — существующая модель

- **Модель:** Славутич-УТ; файл `assets/models/glider_slavutich_ut.glb`, параметры — `tools/blender/glider_params.json` → `wings.slavutich_ut`, конфиг — `configs/wings/slavutich_ut.json`.
- **Класс:** советское учебное однообшивочное мачтовое, 1979. Группа игры: `soviet`.
- **Что есть сейчас:** размах 8,81 м, площадь в конфиге 17,46 м², в плане по модели 17,5 м²; угол носа 118°, хорда у корня/на конце 3/1,12 м, лат на сторону 7, двойная поверхность нет (нижняя обшивка на 0,12 хорды), кингпост 1,3 м, подвес: нос на 1,65 м впереди; двугранность 2,5°, закрутка 17°.
- **Конструкция:** мачтовое.

### Что менять

Числовых правок нет.

Без изменений, подтверждено паспортом: паспортов этого семейства в наборе нет — числа не меняются.

- Паспортов нет: 3D-модель не менять (данные — `docs/plan/wings_lineup.md` §1.1, `docs/research/wing_sources.md`).

### Источники

- Прежние источники модели — `docs/plan/wings_lineup.md`, `docs/research/wing_sources.md`; паспортов в наборе нет.
- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.

### Открытые вопросы

- нет

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел E9. «Апогей» (В. В. Мысенко) (`apogee`) — существующая модель

- **Модель:** «Апогей» (В. В. Мысенко); файл `assets/models/glider_apogee.glb`, параметры — `tools/blender/glider_params.json` → `wings.apogee`, конфиг — `configs/wings/apogee.json`.
- **Класс:** советское мачтовое двухобшивочное 80 %, 1986–. Группа игры: `soviet`.
- **Что есть сейчас:** размах 9,9 м, площадь в конфиге 16 м², в плане по модели 16 м²; угол носа 122°, хорда у корня/на конце 2,75/0,65 м, лат на сторону 9, двойная поверхность да (нижняя обшивка на 0,8 хорды), кингпост 1,25 м, подвес: нос на 1,55 м впереди; двугранность 2,5°, закрутка 16°.
- **Конструкция:** мачтовое.

### Что менять

Числовых правок нет.

Без изменений, подтверждено паспортом: паспортов этого семейства в наборе нет — числа не меняются.

- Паспортов нет (данные — со слов пилота): 3D-модель не менять (`docs/plan/wings_lineup.md` §1.2, §9).

### Источники

- Прежние источники модели — `docs/plan/wings_lineup.md`, `docs/research/wing_sources.md`; паспортов в наборе нет.
- Правки конфига и противоречия данных — `docs/research/wings_config_sources.md`.

### Открытые вопросы

- нет

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N1. Icaro Piuma (`icaro_piuma`) — новая модель, приоритет P1

- **Модель:** Icaro Piuma; будущий файл `assets/models/glider_icaro_piuma.glb`, запись `tools/blender/glider_params.json` → `wings.icaro_piuma` (новая), конфиг `configs/wings/icaro_piuma.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** рекреационное/учебное (DHV 1), мачтовое, двойная поверхность ≈ 30 %. Предлагаемая группа игры: `trainer` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «The Piuma includes a kingpost. With a high aspect ratio comparable to most topless gliders, this wing balances the performance of » (https://www.icaro2000.com/Products/Hanggliders/Piuma/Piuma-2025.htm).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** с 2019.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Profiled downtubes with rubber grip surface; Floating crossbar; Elliptical wingtips; Semi-automatic nose fairing.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.training` из `glider_params.json` (модель `glider_training.glb`: 8 лат на сторону, угол носа 122°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | icaro_piuma | id модели; `out` = `glider_icaro_piuma` |
| `span_m` | 9,8 | паспорт (опорный размер M) |
| `area_m2` | 16,04 | паспорт, опорный размер M |
| `nose_angle_deg` | 120 | паспорт |
| `root_chord_m / tip_chord_m` | 2,53 / 0,89 | форма базы (отношение хорд 0,353) пересчитана под паспортные размах и площадь; площадь в плане при этом 16 м² |
| `nose_forward_m` | 1,44 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 7 | паспорт: верхних лат всего 14 ⇒ на сторону 7 |
| `double_surface / lower_cover` | false / 0,3 | паспорт: нижняя обшивка 30 % — однообшивочное с частичной нижней обшивкой |
| `kingpost_m` | 1,25 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,55 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Паспорт полный и свежий (2019), есть верхние/нижние латы (8+8 на схеме). Угол носа 120° одинаков у всех размеров — используется как есть.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Piuma M | 16,04 | 9,8 | 6 | 24 | 70–90 | 30 | 80 | 120 | 14 |
| Piuma S | 13,76 | 9 | 6 | 21,5 | 55–75 | 30 | 80 | 120 | 14 |
| Piuma L | 17,35 | 10,1 | 5,7 | 25 | 85–120 | 30 | 80 | 120 | 14 |
| Piuma XL | 20,37 | 10,73 | 5,7 | 33 | 110–180 | 30 | 70 | 120 | 14 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `nose_angle` = 120 ° — «Nose angle ° 120»
- `wingspan` = 9800 мм — «Wingspan m 9.80»
- `wingspan_with_tips` = 9960 мм — «Wingspan with wingtips m 9.96»
- `battens` = 12  — «Battens (upper + nose always in) n 12 + 2»
- `wing_surface_with_wingtips` = 173,7  — «Wing Surface with wingtips sq ft 173.7»
- `wingspan_with_tips` = 9997,4 мм — «Wing Span with wingtips ft 32.8»
- `aspect_ratio_without_wingtips` = 6  — «Aspect Ratio with/without wingtips 6.0 / 6.2»
- `aspect_ratio_with_wingtips` = 6,2  — «Aspect Ratio with/without wingtips 6.0 / 6.2»
- `battens_upper` = 12  — «Battens (upper + lower) n 12 + 2»
- `battens_lower` = 2  — «Battens (upper + lower) n 12 + 2»
- `wing_surface` = 16  — «Wing Surface ... M ... 15.98 sq m»
- `wing_surface_with_wingtips` = 16  — «Wing Surface with wingtips ... M ... 16.03 sq m»
- `wingspan_with_tips` = 9940 мм — «Wing Span with wingtips ... M ... 9.94 m»
- `aspect_ratio` = 6  — «Aspect Ratio with/without wingtips ... M ... 6.0 / 6.2»
- `double_surface` = None  — «Double Surface ... 30%»
- `battens` = 14  — «Anzahl Latten 14»

### Источники

- https://www.icaro2000.com/Products/Hanggliders/Piuma/Piuma 2019-1-En.pdf
- https://www.icaro2000.com/Products/Hanggliders/Piuma/Piuma Spec imperial.pdf
- https://www.icaro2000.com/Products/Hanggliders/Piuma/Piuma Spec metric.pdf
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_03)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_10)
- Номера DHV-сертификатов: DHV 01-0498-19, DHV 01-0499-19, DHV 01-0497-19
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Icaro|Piuma||M`, `Icaro|Piuma||S`, `Icaro|Piuma||L`, `Icaro|Piuma||XL`).

### Открытые вопросы

- нет

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N2. Moyes Malibu 2 (`moyes_malibu2`) — новая модель, приоритет P1

- **Модель:** Moyes Malibu 2; будущий файл `assets/models/glider_moyes_malibu2.glb`, запись `tools/blender/glider_params.json` → `wings.moyes_malibu2` (новая), конфиг `configs/wings/moyes_malibu2.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** рекреационное/учебное (DHV 1), мачтовое, двойная поверхность ≈ 20 %. Предлагаемая группа игры: `trainer` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «The wing is cable braced from a single kingpost.» (https://www.moyes.com.au/products/hang-gliders/malibu2).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** преемственность: original Malibu 190 (mid-2000s) → Malibu 2.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Aluminium tubing construction, 8 battens mentioned in specs, aircraft for beginner and specialist dune gooning.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.training` из `glider_params.json` (модель `glider_training.glb`: 8 лат на сторону, угол носа 122°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | moyes_malibu2 | id модели; `out` = `glider_moyes_malibu2` |
| `span_m` | 9,1 | паспорт (опорный размер 166) |
| `area_m2` | 15,4 | паспорт, опорный размер 166 |
| `nose_angle_deg` | 120,5 | паспорт |
| `root_chord_m / tip_chord_m` | 2,62 / 0,92 | форма базы (отношение хорд 0,353) пересчитана под паспортные размах и площадь; площадь в плане при этом 15,38 м² |
| `nose_forward_m` | 1,66 | паспорт: положение ЦТ от носа киля 1658 мм |
| `battens_per_side` | 7 | паспорт: верхних лат всего 15 ⇒ на сторону 7 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | false / 0,2 | паспорт: нижняя обшивка 20 % — однообшивочное с частичной нижней обшивкой |
| `kingpost_m` | 1,25 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,55 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Есть положение ЦТ от носа киля (cg_front_of_keel) — использовать как `nose_forward_m`.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Malibu 2 166 | 15,4 | 9,1 | 5,5 | 24 | 60–110 | 20 | 70 | 120,5 | 15 |
| Malibu 2 188 | 17,5 | 10,1 | 5,8 | 25 | 80–126 | 20 | 70 | 120,5 | 15 |
| Malibu 188 | 17,5 | 10,1 | — | 25 | — | 20 | 70 | — | 15 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `cg_front_of_keel` = 1658 мм — «1658 mm (65.3 inches)»
- `battens_bottom` = 0  — «Number of Battens Bottom 0»
- `nose_angle` = 120,5 ° — «120.5 degrees»
- `battens` = 15  — «Number of Battens Top 15»

### Источники

- https://www.moyes.com.au/products/hang-gliders/malibu2/specifications
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_02)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_09)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_13)
- Номера DHV-сертификатов: DHV 01-0486-16, DHV 01-0488-16, DHV 01-0442-09
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Moyes|Malibu|2|166`, `Moyes|Malibu|2|188`, `Moyes|Malibu||188`).

### Открытые вопросы

- нет

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N3. Airborne F2 (`air_f2`) — новая модель, приоритет P1

- **Модель:** Airborne F2; будущий файл `assets/models/glider_air_f2.glb`, запись `tools/blender/glider_params.json` → `wings.air_f2` (новая), конфиг `configs/wings/air_f2.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** учебное (HGMA/USHPA II Novice), мачтовое, двойная поверхность 30 %. Предлагаемая группа игры: `trainer` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — предположение координатора (прямого подтверждения в найденных источниках нет; проверить по фото производителя).
- **Заметки по виду (из выборки, проверять по первоисточнику):** Lightweight novice/recreational glider; Hinged battens as standard; Round down tube knuckle for optional speed bars; Nose angle: 118 degrees.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.training` из `glider_params.json` (модель `glider_training.glb`: 8 лат на сторону, угол носа 122°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | air_f2 | id модели; `out` = `glider_air_f2` |
| `span_m` | 10,1 | паспорт (опорный размер 190) |
| `area_m2` | 17,7 | паспорт, опорный размер 190 |
| `nose_angle_deg` | 118 | паспорт |
| `root_chord_m / tip_chord_m` | 2,71 / 0,96 | форма базы (отношение хорд 0,353) пересчитана под паспортные размах и площадь; площадь в плане при этом 17,7 м² |
| `nose_forward_m` | 1,65 | паспорт: петля подвеса от носа 1625–1675 мм (середина) |
| `battens_per_side` | 7 | паспорт: верхних лат всего 15 ⇒ на сторону 7 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | false / 0,3 | паспорт: нижняя обшивка 30 % — однообшивочное с частичной нижней обшивкой |
| `kingpost_m` | 1,25 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,6 | паспорт: нос→поперечина 3530 мм при длине передней кромки ≈ 5,89 м |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Есть размеры каркаса: диаметр передней кромки, хорда в 3 футах от конца, положение поперечины от носа (`leading_edge_nose_to_crossbar`), петля подвеса (keel_hang_loop) — использовать для `crossbar_u` и `nose_forward_m`.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| F2 190 | 17,7 | 10,1 | 5,8 | 23 | 70–120 | 30 | 80 | 118 | 15 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `leading_edge_nose_to_crossbar` = 3530 мм — «Nose Plate anchor hole to crossbar plate attachment hole 3530 mm»
- `leading_edge_nose_to_rear_sail` = 5810 мм — «Nose Plate anchor hole to rear sail attachment point 5810 mm»
- `leading_edge_dia_front` = 50 мм — «Outside diameter at nose 50 mm»
- `crossbar_dia` = 52 мм — «Outside diameter at cross bar 52 mm»
- `leading_edge_rear_od` = 50 мм — «Outside diameter at rear sail attachment point 50 mm»
- `crossbar_length_pin_to_pin` = 3100 мм — «Overall pin to pin length from leading edge attachment point to hinge bolt at glider centr»
- `crossbar_dia` = 62 мм — «Largest outside diameter 62 mm»
- `keel_load_bearing_pin` = 1455 мм — «The cross bar centre load bearing pin 1455 mm»
- `keel_hang_loop_forward` = 1625 мм — «The pilot hang loop Fwd 1625 mm»
- `keel_hang_loop_rear` = 1675 мм — «The pilot hang loop Rear 1675 mm»
- `sail_chord_3ft_outboard` = 2280 мм — «Chord length at 3 ft outboard of centre line 2280 mm»
- `sail_chord_3ft_inboard_tip` = 1225 мм — «Chord length at 3 ft inboard of tip 1225 mm»
- `wingspan` = 10100 мм — «Span (extreme tip to tip) 10100 mm»
- `nose_angle` = 118 ° — «NOSE ANGLE 118 degrees»
- `battens` = 15  — «BATTENS 15»

### Источники

- https://www.airborne.com.au/images/manuals/8439.pdf
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Airborne|F2||190`).

### Открытые вопросы

- Тип конструкции принят по предположению — подтвердить по фото производителя.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N4. Aeros Fox (`aeros_fox`) — новая модель, приоритет P1

- **Модель:** Aeros Fox; будущий файл `assets/models/glider_aeros_fox.glb`, запись `tools/blender/glider_params.json` → `wings.aeros_fox` (новая), конфиг `configs/wings/aeros_fox.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** учебное (DHV 1), мачтовое, двойная поверхность 25–30 %. Предлагаемая группа игры: `trainer` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «The Fox is a kingpost design (traditional A-frame configuration) featuring a 'Finsterwalder streamlined A-frame'» (https://www.aeros.com.ua/structure/hg/fox_en.php).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: no.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Kingpost with Finsterwalder streamlined A-frame, frame made with lightweight 7075 alloy tubes, airborne batten tips, optional APEN 6 composite X-lam cloth, vers.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.target` из `glider_params.json` (модель `glider_target.glb`: 8 лат на сторону, угол носа 120°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | aeros_fox | id модели; `out` = `glider_aeros_fox` |
| `span_m` | 9,6 | паспорт (размер в паспорте не указан) |
| `area_m2` | 16,2 | паспорт (размер в паспорте не указан) |
| `nose_angle_deg` | 120 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,60 / 0,93 | форма базы (отношение хорд 0,358) пересчитана под паспортные размах и площадь; площадь в плане при этом 16,19 м² |
| `nose_forward_m` | 1,48 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 7 | паспорт: верхних лат всего 15 ⇒ на сторону 7 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | false / 0,25 | паспорт: нижняя обшивка 25 % — однообшивочное с частичной нижней обшивкой |
| `kingpost_m` | 1,25 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,55 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Размеры записаны без указания размера модели: запись «без размера» = 16,2 м² (близка к Target 16), вторая — Fox 13 (13,4 м²).

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Fox | 16,2 | 9,6 | — | 25,2 | — | 25 | 75 | — | 15 |
| Fox 13 | 13,4 | 8,6 | — | 20,6 | — | 30 | 70 | — | 13 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 15  — «15 / 0»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_00)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_07)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_02)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_09)
- Номера DHV-сертификатов: DHV 01-0457-10, DHV 01-0484-16
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Aeros|Fox||`, `Aeros|Fox||13`).

### Открытые вопросы

- Связь с Aeros Target (замена?) — см. `out/construction/batch_b.json`.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N5. Delta Flugschule Condor Crex 3 (`condor_crex3`) — новая модель, приоритет P2

- **Модель:** Delta Flugschule Condor Crex 3; будущий файл `assets/models/glider_condor_crex3.glb`, запись `tools/blender/glider_params.json` → `wings.condor_crex3` (новая), конфиг `configs/wings/condor_crex3.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** учебное (DHV 1), мачтовое, двойная поверхность 60 %. Предлагаемая группа игры: `trainer` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — предположение координатора (прямого подтверждения в найденных источниках нет; проверить по фото производителя).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** с 2015.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Wing span 9.60 m; Aspect ratio 6.4; Weight 23 kg; Maximum pilot weight 100 kg.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.training` из `glider_params.json` (модель `glider_training.glb`: 8 лат на сторону, угол носа 122°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | condor_crex3 | id модели; `out` = `glider_condor_crex3` |
| `span_m` | 9,6 | паспорт (размер в паспорте не указан) |
| `area_m2` | 14,5 | паспорт (размер в паспорте не указан) |
| `nose_angle_deg` | 122 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,34 / 0,83 | форма базы (отношение хорд 0,353) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,53 м² |
| `nose_forward_m` | 1,33 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 7 | паспорт: верхних лат всего 15 ⇒ на сторону 7 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,6 | паспорт: двойная поверхность 60 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,25 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,55 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Данные только из карточки DHV (площадь, размах, масса, число латов, Vne); угла носа нет.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Crex 3 | 14,5 | 9,6 | — | 23 | — | 60 | 80 | — | 15 |
| Crex 14.5 | 14,5 | 9,6 | — | 23,7 | — | 60 | 70 | — | 15 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 15  — «Anzahl Latten  15»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_04)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_02)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_09)
- Номера DHV-сертификатов: DHV 01-0505-24, DHV 01-0483-16
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Delta Flugschule Condor|Crex|3|`, `Delta Flugschule Condor|Crex||14.5`).

### Открытые вопросы

- Угол носа и высота кингпоста неизвестны — по базе.
- Угол носа в паспорте не найден — значение базы.
- Тип конструкции принят по предположению — подтвердить по фото производителя.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N6. Delta Flugschule Condor FLEX / Lifter (`condor_flex`) — новая модель, приоритет P2

- **Модель:** Delta Flugschule Condor FLEX / Lifter; будущий файл `assets/models/glider_condor_flex.glb`, запись `tools/blender/glider_params.json` → `wings.condor_flex` (новая), конфиг `configs/wings/condor_flex.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** учебное (DHV 1), лёгкое однообшивочное (двойная поверхность 20 %). Предлагаемая группа игры: `trainer` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — предположение координатора (прямого подтверждения в найденных источниках нет; проверить по фото производителя).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** с 2019.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Wing span 9.15 m; Aspect ratio 5.2; Weight 17 kg; Pilot weight range 50–98 kg.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.training` из `glider_params.json` (модель `glider_training.glb`: 8 лат на сторону, угол носа 122°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | condor_flex | id модели; `out` = `glider_condor_flex` |
| `span_m` | 9,2 | паспорт (размер в паспорте не указан) |
| `area_m2` | 16 | паспорт (размер в паспорте не указан) |
| `nose_angle_deg` | 122 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,69 / 0,95 | форма базы (отношение хорд 0,353) пересчитана под паспортные размах и площадь; площадь в плане при этом 15,99 м² |
| `nose_forward_m` | 1,53 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 5 | паспорт: верхних лат всего 11 ⇒ на сторону 5 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | false / 0,2 | паспорт: нижняя обшивка 20 % — однообшивочное с частичной нижней обшивкой |
| `kingpost_m` | 1,25 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,55 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Lifter и FLEX в карточках DHV идентичны (16,0 м², 9,2 м, 17,6 кг, 11 лат) — одна модель, разные годы.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| FLEX | 16 | 9,2 | — | 17,6 | — | 20 | 80 | — | 11 |
| Lifter | 16 | 9,2 | — | 17,6 | — | 20 | 70 | — | 11 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 11  — «Anzahl Latten 11»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_03)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_10)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_13)
- Номера DHV-сертификатов: DHV 01-0496-19, DHV 01-0434-08
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Delta Flugschule Condor|FLEX||`, `Delta Flugschule Condor|Lifter||`).

### Открытые вопросы

- Угол носа в паспорте не найден — значение базы.
- Тип конструкции принят по предположению — подтвердить по фото производителя.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N7. Flugsport Skypoint Funky (`fs_funky`) — новая модель, приоритет P2

- **Модель:** Flugsport Skypoint Funky; будущий файл `assets/models/glider_fs_funky.glb`, запись `tools/blender/glider_params.json` → `wings.fs_funky` (новая), конфиг `configs/wings/fs_funky.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** учебное (DHV 1), историческое. Предлагаемая группа игры: `trainer` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «The Funky includes a kingpost that can be erected and features tubes made from high-strength Perunal 7075 aluminum» (https://en.wikipedia.org/wiki/Seedwings_Europe).
- **Заметки по виду (из выборки, проверять по первоисточнику):** High-strength Perunal 7075 aluminum tubes.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.training` из `glider_params.json` (модель `glider_training.glb`: 8 лат на сторону, угол носа 122°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | fs_funky | id модели; `out` = `glider_fs_funky` |
| `span_m` | 9,5 | паспорт (опорный размер 15) |
| `area_m2` | 15,3 | паспорт, опорный размер 15 |
| `nose_angle_deg` | 122 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,49 / 0,88 | форма базы (отношение хорд 0,353) пересчитана под паспортные размах и площадь; площадь в плане при этом 15,29 м² |
| `nose_forward_m` | 1,41 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 7 | паспорт: верхних лат всего 14 ⇒ на сторону 7 |
| `double_surface / lower_cover` | false / 0,3 | паспорт: нижняя обшивка 30 % — однообшивочное с частичной нижней обшивкой |
| `kingpost_m` | 1,25 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,55 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Только карточка DHV 2006.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Funky 15 | 15,3 | 9,5 | — | 23 | — | 30 | 70 | — | 14 |
| Funky 17 | 17,3 | 9,9 | — | 25 | — | 30 | 70 | — | 14 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 14  — «Anzahl Latten  14»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_04)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- Номера DHV-сертификатов: DHV 01-0416-06, DHV 01-0417-06
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Flugsport Skypoint|Funky||15`, `Flugsport Skypoint|Funky||17`).

### Открытые вопросы

- Угол носа неизвестен.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N8. Flugsport Skypoint Space (`fs_space`) — новая модель, приоритет P2

- **Модель:** Flugsport Skypoint Space; будущий файл `assets/models/glider_fs_space.glb`, запись `tools/blender/glider_params.json` → `wings.fs_space` (новая), конфиг `configs/wings/fs_space.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** учебное/начальное (DHV 1-2), двойная поверхность 72 %, историческое. Предлагаемая группа игры: `trainer` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — предположение координатора (прямого подтверждения в найденных источниках нет; проверить по фото производителя).
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.training` из `glider_params.json` (модель `glider_training.glb`: 8 лат на сторону, угол носа 122°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | fs_space | id модели; `out` = `glider_fs_space` |
| `span_m` | 9,5 | паспорт (опорный размер 14) |
| `area_m2` | 14,2 | паспорт, опорный размер 14 |
| `nose_angle_deg` | 122 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,31 / 0,82 | форма базы (отношение хорд 0,353) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,2 м² |
| `nose_forward_m` | 1,31 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 7 | паспорт: верхних лат всего 14 ⇒ на сторону 7 |
| `double_surface / lower_cover` | true / 0,72 | паспорт: двойная поверхность 72 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,25 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,55 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Только карточка DHV 2007–2008.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Space 14 | 14,2 | 9,5 | — | 25,5 | — | 72 | 80 | — | 14 |
| Space 16 | 15,9 | 9,8 | — | 27 | — | 72 | — | — | 14 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 14  — «14 / 2»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_13)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_05)
- Номера DHV-сертификатов: DHV 01-0436-08, DHV 01-0423-07
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Flugsport Skypoint|Space||14`, `Flugsport Skypoint|Space||16`).

### Открытые вопросы

- Угол носа неизвестен.
- Угол носа в паспорте не найден — значение базы.
- Тип конструкции принят по предположению — подтвердить по фото производителя.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N9. Wills Wing Eagle (`ww_eagle`) — новая модель, приоритет P2

- **Модель:** Wills Wing Eagle; будущий файл `assets/models/glider_ww_eagle.glb`, запись `tools/blender/glider_params.json` → `wings.ww_eagle` (новая), конфиг `configs/wings/ww_eagle.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** начальное–среднее (USHPA II Novice), мачтовое двухобшивочное (обтекаемый кингпост), историческое. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по паспорту (geometry `kingpost_design` = «streamlined», страница производителя).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: no; с 2000 по 2005.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Developed to bridge the performance gap between Falcon and Ultra Sport models; Quick-mount vertical stabilizer that pilots could install/remove; 7075-T6 aluminum leading edges and keel; Full Mylar pocket construction.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.magic` из `glider_params.json` (модель `glider_magic.glb`: 11 лат на сторону, угол носа 124°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_eagle | id модели; `out` = `glider_ww_eagle` |
| `span_m` | 9,75 | паспорт (опорный размер 164) |
| `area_m2` | 15,24 | паспорт, опорный размер 164 |
| `nose_angle_deg` | 124 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,48 / 0,78 | форма базы (отношение хорд 0,314) пересчитана под паспортные размах и площадь; площадь в плане при этом 15,23 м² |
| `nose_forward_m` | 1,41 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 11 | паспорта нет — как у базы |
| `double_surface / lower_cover` | true / 0,6 | паспорта нет — как у базы |
| `kingpost_m` | 1,2 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,57 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4595`, `k_t = 0,5405` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Из страницы архива: «Double surface sail with enclosed crossbar», «Streamlined kingpost», 7075-T6 кромки и киль, съёмный вертикальный стабилизатор (quick-mount) — стабилизатор в 3D-модель не добавлять (нет в контракте), обтекаемый кингпост — сделать каплевидным сечением.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Eagle 164 | 15,24 | 9,75 | 6,2 | 26,5 | 68–113 | — | 85 | — | — |
| Eagle 145 | 13,47 | 9,14 | 6,2 | 23,8 | 59–91 | — | 77 | — | — |
| Eagle 180 | 16,72 | 10,15 | 6,2 | 28,3 | 79–125 | — | 77 | — | — |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `double_surface` = yes  — «Double surface sail with enclosed crossbar»
- `leading_edge_material` = 7075-T6  — «7075-T6 leading edges and keel»
- `keel_material` = 7075-T6  — «7075-T6 leading edges and keel»
- `kingpost_design` = streamlined  — «Streamlined kingpost»
- `vertical_stabilizer` = quick-mount removable  — «Quick-mount vertical stabilizer (can be flown with or without)»
- `batten_type` = pre-formed 7075-T6  — «Pre-formed 7075-T6 battens»

### Источники

- https://www.willswing.com/hang-gliders/archive/eagle/
- https://www.willswing.com/hang-glider-placard-specifications/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Eagle||164`, `Wills Wing|Eagle||145`, `Wills Wing|Eagle||180`).

### Открытые вопросы

- Процент двойной поверхности на странице не назван.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N10. Wills Wing Sport 3 (`ww_sport3`) — новая модель, приоритет P1

- **Модель:** Wills Wing Sport 3; будущий файл `assets/models/glider_ww_sport3.glb`, запись `tools/blender/glider_params.json` → `wings.ww_sport3` (новая), конфиг `configs/wings/ww_sport3.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (USHPA III Intermediate; DHV 3 по сертификату 2025), мачтовое двухобшивочное 80–85 %. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «The Sport 3 is a kingposted glider... maintains this kingpost configuration» (https://www.willswing.com/hang-gliders/sport-3/).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2019.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Kickstand Stinger for easier setup/breakdown; Optional carbon fiber raked tips to increase effective aspect ratio; Redesigned sail with lower twist for improved high-speed performance.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_sport3 | id модели; `out` = `glider_ww_sport3` |
| `span_m` | 9,6 | паспорт (опорный размер 155) |
| `area_m2` | 14,4 | паспорт, опорный размер 155 |
| `nose_angle_deg` | 127 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,50 / 0,66 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,37 м² |
| `nose_forward_m` | 1,42 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 7 | паспорт: верхних лат всего 14 ⇒ на сторону 7 |
| `double_surface / lower_cover` | true / 0,85 | паспорт: двойная поверхность 85 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Актуальная модель (2019–). В паспорте есть число латов (14–17), двойная поверхность 80–85 %.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Sport 3 155 | 14,4 | 9,6 | 6,4 | 28,6 | 68–113 | 85 | 85 | — | 14 |
| Sport 3 135 | 12,52 | 8,92 | 6,4 | 24,5 | 61–92 | 85 | 85 | — | — |
| Sport 3 170 | 15,8 | 10,1 | 6,4 | 29,5 | 79–141 | 80 | 85 | — | 17 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 14  — «14 / 4»

### Источники

- https://www.willswing.com/hang-glider-placard-specifications/
- https://www.willswing.com/hang-gliders/sport-3/
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_05)
- Номера DHV-сертификатов: DHV 01-0508-25, DHV 01-0509-25
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Sport 3||155`, `Wills Wing|Sport 3||135`, `Wills Wing|Sport 3||170`).

### Открытые вопросы

- Угол носа у Sport 3 на странице не назван.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N11. Wills Wing U2 (`ww_u2`) — новая модель, приоритет P1

- **Модель:** Wills Wing U2; будущий файл `assets/models/glider_ww_u2.glb`, запись `tools/blender/glider_params.json` → `wings.ww_u2` (новая), конфиг `configs/wings/ww_u2.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее–спортивное (USHPA III; DHV 2-3), мачтовое двухобшивочное 84–85 %, VG. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «Kingpost design with internal stability system (no reflex bridles)» (https://www.willswing.com/hang-gliders/u2/).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2003.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Lightweight intermediate-level glider; Litestream control bar with streamlined aluminum components; Uncoated 3/32 1×19 lower cables for drag reduction; Curved tip planform with premium sailcloth (205MT standard).
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_u2 | id модели; `out` = `glider_ww_u2` |
| `span_m` | 9,5 | паспорт (опорный размер 145) |
| `area_m2` | 13,5 | паспорт, опорный размер 145 |
| `nose_angle_deg` | 126,5 | паспорт |
| `root_chord_m / tip_chord_m` | 2,37 / 0,63 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,51 м² |
| `nose_forward_m` | 1,35 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 8 | паспорт: верхних лат всего 17 ⇒ на сторону 8 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,84 | паспорт: двойная поверхность 84 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Есть угол носа 126,5° (VG), число латов 17–20, положение точки поляры WW (мин. снижение 0,89 м/с на 37 км/ч).

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| U2 145 | 13,5 | 9,5 | 6,8 | 27,6 | 64–100 | 84 | 85 | 126,5 | 17 |
| U2 160 | 14,9 | 10,1 | 6,8 | 31 | 73–118 | 85 | 90 | 126,5 | 20 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `nose_angle` = 125 ° — «Nose Angle (deg) 125 – 128»
- `nose_angle` = 128 ° — «Nose Angle (deg) 125 – 128»
- `battens` = 17  — «17 / 4»

### Источники

- https://www.willswing.com/hang-glider-placard-specifications/
- https://www.willswing.com/hang-gliders/u2/
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_01)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_04)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- Номера DHV-сертификатов: DHV 01-0477-13, DHV 01-0409-05
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|U2||145`, `Wills Wing|U2||160`).

### Открытые вопросы

- нет

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N12. Aeros Discus (`aeros_discus`) — новая модель, приоритет P1

- **Модель:** Aeros Discus; будущий файл `assets/models/glider_aeros_discus.glb`, запись `tools/blender/glider_params.json` → `wings.aeros_discus` (новая), конфиг `configs/wings/aeros_discus.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (DHV 2; 2-3 у размера 15), мачтовое двухобшивочное 85 %. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «Its wing is cable braced with a kingpost. The hang loop fore and aft position is adjusted by repositioning the kingpost on the kee» (https://en.wikipedia.org/wiki/Aeros_Discus).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2002.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Versions: Discus (standard), Discus A/B (different breakdown length), Discus M (motorized harness compatible), Discus T (trike-mounted), Discus C (competition v.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | aeros_discus | id модели; `out` = `glider_aeros_discus` |
| `span_m` | 10 | паспорт (опорный размер 14) |
| `area_m2` | 13,7 | паспорт, опорный размер 14 |
| `nose_angle_deg` | 125 | паспорт |
| `root_chord_m / tip_chord_m` | 2,29 / 0,60 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,69 м² |
| `nose_forward_m` | 1,3 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 9 | паспорт: верхних лат всего 18 ⇒ на сторону 9 |
| `double_surface / lower_cover` | true / 0,85 | паспорт: двойная поверхность 85 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Руководство даёт угол носа 125°, 18–20 лат, размеры каркаса (диаметры передней/задней трубы — `leading_edge_*`).

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Discus 14 | 13,7 | 10 | 7,3 | 31 | 75–115 | 85 | 90 | 125 | 18 |
| Discus 12 | 11,6 | 9,2 | 7,3 | 25 | 50–80 | — | — | 125 | 18 |
| Discus 13 | 12,8 | 9,6 | 7,2 | 30 | 65–100 | — | — | 125 | 20 |
| Discus 15 | 14,7 | 10,3 | 7,2 | 33,5 | 85–125 | 85 | 90 | 125 | 20 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `leading_edge_dia_front` = 60 мм — «front leading edge is 60 mm oversleeved with 62 mm at the crossbar»
- `front_leading_edge_at_crossbar` = 62 мм — «62 mm at the crossbar junction»
- `rear_leading_edge_diameter` = 50 мм — «rear leading edge is 50 mm oversleeved with 52 mm at the washout»
- `rear_leading_edge_at_washout` = 52 мм — «52 mm at the washout tube outboard sprog attachment point»
- `tip_wand_clevis_pin_position` = 12 мм — «clevis pin and a small screw 12 mm from the end of the tube»
- `sail_mount_strap_clevis_pin_position` = 100 мм — «clevis pin located 100 mm from the end of the leading edge»
- `batten_alignment_tolerance` = 3 мм — «not be any deviation of more than 3 mm (1/8'') from one batten»
- `nose_angle` = 125 ° — «Nose angle, ° 125-128»
- `battens` = 20  — «Number of upper sail battens 20»
- `battens` = 18  — «18 / 4»

### Источники

- https://www.delta-club-82.com/bible/manuels/discus.pdf
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_01)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_04)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- Номера DHV-сертификатов: DHV 01-0465-13, DHV 01-0415-06
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Aeros|Discus||14`, `Aeros|Discus||12`, `Aeros|Discus||13`, `Aeros|Discus||15`).

### Открытые вопросы

- Разновидности Discus / Discus T / Discus C — какая мачтовая (см. batch_b).

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N13. Airborne Sting 3 (`air_sting3`) — новая модель, приоритет P1

- **Модель:** Airborne Sting 3; будущий файл `assets/models/glider_air_sting3.glb`, запись `tools/blender/glider_params.json` → `wings.air_sting3` (новая), конфиг `configs/wings/air_sting3.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (DHV 2), двойная поверхность 75 %, VG; версии Sport/Race. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «Constructed using 7075 airframe, fitted with faired king post, downtubes and speed bar as standard» (https://www.airborne.com.au/images/manuals/Sting-3-Rev1-Manual.pdf).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; преемственность: Available in Sport and Race versions.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Recreational/XC design with excellent climbing characteristics; Faired king post as standard; Speed bar included as standard; Easy launch and landing properties.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | air_sting3 | id модели; `out` = `glider_air_sting3` |
| `span_m` | 9,1 | паспорт (опорный размер 154) |
| `area_m2` | 14,33 | паспорт, опорный размер 154 |
| `nose_angle_deg` | 121 | паспорт |
| `root_chord_m / tip_chord_m` | 2,63 / 0,69 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,31 м² |
| `nose_forward_m` | 1,61 | паспорт: петля подвеса от носа 1600–1630 мм (середина) |
| `battens_per_side` | 8 | паспорт: верхних лат всего 16 ⇒ на сторону 8 |
| `double_surface / lower_cover` | true / 0,75 | паспорт: двойная поверхность 75 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,59 | паспорт: нос→поперечина 3097 мм при длине передней кромки ≈ 5,23 м |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Угол носа 121°, 16 лат, размах 9,1 м при площади 14,33 м² (удлинение 5,7 — заметно ниже, чем у Laminar) — хорды корня/конца пересчитать по формуле ниже.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Sting 3 154 | 14,33 | 9,1 | 5,7 | 26,3 | 50–100 | 75 | 90 | 121 | 16 |
| Sting 3 168 | 15,6 | 9,5 | — | 30 | — | 75 | 90 | — | 18 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `nose_to_crossbar` = 3097 мм — «Nose plate anchor hole to crossbar attachment hole 3097 mm»
- `nose_to_rear_sail` = 5420 мм — «Nose plate anchor hole to rear sail attachment point 5420 mm»
- `leading_edge_dia_front` = 50 мм — «Outside diameter at nose 50 mm»
- `crossbar_dia` = 52 мм — «Outside diameter at cross bar 52 mm»
- `rear_sail_diameter` = 50 мм — «Outside diameter at rear sail attachment point 50 mm»
- `crossbar_pin_length` = 2680 мм — «Overall pin to pin length from leading edge attachment point 2680 mm»
- `crossbar_dia` = 62 мм — «Largest outside diameter 62 mm»
- `keel_load_pin` = 1290 мм — «The cross bar centre load bearing pin 1290 mm»
- `hang_loop_forward` = 1600 мм — «The pilot hang loop Fwd 1600 mm»
- `hang_loop_rear` = 1630 мм — «The pilot hang loop Rear 1630 mm»
- `chord_outboard` = 2095 мм — «Chord length at 3 ft outboard of centre line 2095 mm»
- `chord_inboard_tip` = 1070 мм — «Chord length at 3 ft inboard of tip 1070 mm»
- `wingspan` = 9090 мм — «Span (extreme tip to tip) 9090 mm»
- `nose_angle` = 121 ° — «NOSE ANGLE 121 degrees»
- `battens` = 22  — «BATTENS 22»
- `battens` = 16  — «16 / 6»

### Источники

- https://www.airborne.com.au/images/manuals/108841%20STING%203%20Manual.pdf
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_13)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_14)
- Номера DHV-сертификатов: DHV 01-0438-08, DHV 01-0445-09
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Airborne|Sting 3||154`, `Airborne|Sting 3||168`).

### Открытые вопросы

- Версия Race безмачтовая (по данным производителя — проверить в batch_a).

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N14. Icaro Alto (`icaro_alto`) — новая модель, приоритет P1

- **Модель:** Icaro Alto; будущий файл `assets/models/glider_icaro_alto.glb`, запись `tools/blender/glider_params.json` → `wings.icaro_alto` (новая), конфиг `configs/wings/icaro_alto.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (DHV 2-3), двойная поверхность 85 %, VG. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «Kingpost design featuring a new and improved A-frame position with profiled kingpost elements» (https://www.icaro2000.com/Products/Hanggliders/Alto/Alto.htm).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2022; преемственность: evolution of the earlier Orbiter 2 model.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Lighter, stronger aluminum frame (7075 alloy/Ergal); Elliptical wingtips designed to reduce induced drag; Eight battens per wing with snap-fit batten system; Semi-automatic nose fairing with guided upper surface.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | icaro_alto | id модели; `out` = `glider_icaro_alto` |
| `span_m` | 9,98 | паспорт (опорный размер M) |
| `area_m2` | 14,6 | паспорт, опорный размер M |
| `nose_angle_deg` | 127,5 | паспорт |
| `root_chord_m / tip_chord_m` | 2,44 / 0,64 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,56 м² |
| `nose_forward_m` | 1,39 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 9 | паспорт: верхних лат всего 18 ⇒ на сторону 9 |
| `double_surface / lower_cover` | true / 0,85 | паспорт: двойная поверхность 85 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Есть высоты концов лат/кромки и длина троса поперечины — для деталей каркаса (низкий приоритет).

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Alto M | 14,6 | 9,98 | 6,8 | 28,5 | 70–93 | 85 | 90 | 127,5 | 18 |
| Alto S | 13,7 | 9,73 | 6,9 | 27,2 | 60–85 | 85 | 90 | 128 | 18 |
| Alto L | 15,2 | 10,4 | 7 | 29,2 | 85–109 | 85 | 90 | 128 | 18 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `wingspan_with_tips` = 10100 мм — «Wing Span with wingtips m - ft 10.10 – 33.1»
- `wingspan_with_tips` = 10088,9 мм — «Wing Span with wingtips m - ft 10.10 – 33.1»
- `wing_surface_with_wingtips` = 14,7  — «Wing Surface with wingtips m^2 - sq ft 14.73 – 158.6»
- `wing_surface_with_wingtips` = 158,6  — «Wing Surface with wingtips m^2 - sq ft 14.73 – 158.6»
- `aspect_ratio_with_wingtips` = 6,9  — «Aspect Ratio with wingtips 6.9»
- `battens` = 20  — «Battens (Upper + Lower) n° 16 + 4»
- `nose_angle` = 128 ° — «Nose Angle ° 128»
- `crossbar_cable_length` = 1195 мм — «Alto M 1195»
- `position_1_batten_4_height` = 146 мм — «Position 1 #4 + 146»
- `position_2_batten_5_height` = 157 мм — «Position 2 #5 + 157»
- `position_3_batten_6_height` = 121 мм — «Position 3 #6 + 121»
- `position_4_le_tube_end_height` = -135 мм — «Position 4 LE Tube End - 135»
- `nose_angle` = 127 ° — «Nose Angle ° 127»
- `battens` = 18  — «Anzahl Latten 18»

### Источники

- https://www.icaro2000.com/Products/Hanggliders/Alto/Alto 2022 Metric-Imperial data.pdf
- https://www.icaro2000.com/Products/Hanggliders/Alto/Alto 2022-1-En.pdf
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_03)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_10)
- Номера DHV-сертификатов: DHV, DHV 01-0501-22, DHV 01-0511-26, DHV 01-0502-23
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Icaro|Alto||M`, `Icaro|Alto||S`, `Icaro|Alto||L`).

### Открытые вопросы

- Тип (мачтовый/безмачтовый) — по `out/construction/batch_c.json`.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N15. Icaro MastR (`icaro_mastr`) — новая модель, приоритет P1

- **Модель:** Icaro MastR; будущий файл `assets/models/glider_icaro_mastr.glb`, запись `tools/blender/glider_params.json` → `wings.icaro_mastr` (новая), конфиг `configs/wings/icaro_mastr.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** спортивное (DHV 3), двойная поверхность 94–96 %, VG. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «The MastR is a topless glider with a king post, and is essentially the Laminar with a kingpost» — безмачтовое по своему типу, но с небольшим кингпостом и двумя luff-линиями к задней кромке (страница Icaro); верхних тросов нет.
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2007; преемственность: Essentially the Laminar with a kingpost.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Profiled kingpost canted slightly forward reducing parasitic drag; Two luff-lines extend from the kingpost to the trailing edge of the wing; RSQ Polykote sail (rectangular box double-ripstop pattern); Optional technora sail available.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.combat` из `glider_params.json` (модель `glider_combat.glb`: 16 лат на сторону, угол носа 130°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | icaro_mastr | id модели; `out` = `glider_icaro_mastr` |
| `span_m` | 10,4 | паспорт (опорный размер L) |
| `area_m2` | 14,8 | паспорт, опорный размер L |
| `nose_angle_deg` | 131 | паспорт |
| `root_chord_m / tip_chord_m` | 2,46 / 0,56 | форма базы (отношение хорд 0,227) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,83 м² |
| `nose_forward_m` | 1,4 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 11 | паспорт: верхних лат всего 22 ⇒ на сторону 11 |
| `double_surface / lower_cover` | true / 0,94 | паспорт: двойная поверхность 94 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `kingpost_m` | небольшой, наклонён вперёд | цитата: «profiled kingpost canted slightly forward»; высоты числом в паспорте нет — взять по фото производителя |
| `luff_lines` | две линии (положение — по фото) | цитата: «Two luff-lines extend from the kingpost to the trailing edge»; доли по размаху в паспорте нет |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Запись размера M в своде: площадь 10,0 м² — ошибка разбора (вне диапазона), опорный размер — L; площадь M брать по удлинению 7,35 и размаху 10,0 (≈ 13,6 м²) — проверить по PDF.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| MastR L | 14,8 | 10,4 | 7,38 | 31,5 | 85–110 | 94 | 90 | 131 | 22 |
| MastR S | 12,6 | 9,4 | 7,01 | 26,7 | 50–75 | 96 | 90 | 128 | — |
| MastR M | 10 | 10 | 7,35 | 30,5 | 70–90 | 94 | 90 | 131 | 20 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `nose_angle` = 131 ° — «Nose angle deg 131»
- `battens` = 22  — «22 / 4»

### Источники

- https://www.icaro2000.com/ (страница Icaro, файл разбора icaro__mastr)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_13)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_07)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_14)
- Номера DHV-сертификатов: DHV 01-0443-09, DHV 01-0448-09, DHV 01-0444-09
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Icaro|MastR||L`, `Icaro|MastR||S`, `Icaro|MastR||M`).

### Открытые вопросы

- Площадь MastR M — перепроверить по первоисточнику.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N16. Bautek Kite (`bautek_kite`) — новая модель, приоритет P2

- **Модель:** Bautek Kite; будущий файл `assets/models/glider_bautek_kite.glb`, запись `tools/blender/glider_params.json` → `wings.bautek_kite` (новая), конфиг `configs/wings/bautek_kite.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (DHV 2), двойная поверхность 85 %. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «The Kite features a kingpost design with Sturdy, yet lightweight construction» (https://www.bautek.com/english/hanggliders/kite/).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2006; преемственность: Predecessor to Fizz (Fizz developed following 2006 Kite).
- **Заметки по виду (из выборки, проверять по первоисточнику):** 33-foot wingspan; Packs to either 18.7 feet (long) or 12.5 feet (short) configurations; Integrated swivel tips with threaded adjustment; Steel spring-tensioned lower side wires.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | bautek_kite | id модели; `out` = `glider_bautek_kite` |
| `span_m` | 10,15 | паспорт (размер в паспорте не указан) |
| `area_m2` | 13,8 | паспорт (размер в паспорте не указан) |
| `nose_angle_deg` | 128 | паспорт |
| `root_chord_m / tip_chord_m` | 2,27 / 0,60 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,8 м² |
| `nose_forward_m` | 1,29 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 10 | паспорт: верхних лат всего 21 ⇒ на сторону 10 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,85 | паспорт: двойная поверхность 85 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Угол носа 128°, 21 лата.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Kite | 13,8 | 10,15 | 7,5 | 30,4 | — | 85 | 90 | 128 | 21 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `nose_angle` = 128 ° — «Nose angle: 128 deg»
- `battens` = 29  — «Battens: 29 top; 8 bottom»
- `battens` = 21  — «21 / 6»

### Источники

- https://www.bautek.com/english/hanggliders/kite/
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_05)
- Номера DHV-сертификатов: DHV 01-0421-06
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Bautek|Kite||`).

### Открытые вопросы

- нет

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N17. Bautek Astir (`bautek_astir`) — новая модель, приоритет P2

- **Модель:** Bautek Astir; будущий файл `assets/models/glider_bautek_astir.glb`, запись `tools/blender/glider_params.json` → `wings.bautek_astir` (новая), конфиг `configs/wings/bautek_astir.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (DHV 2), двойная поверхность 85 %. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** неизвестен — определить по фото производителя до начала работы.
- **Заметки по виду (из выборки, проверять по первоисточнику):** 34.6 ft wingspan; Pack lengths offered: long 20.2 ft; short 15.4 ft; extra short 9.8 ft; DHV 2 (intermediate) rating; 64 lbs glider weight.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | bautek_astir | id модели; `out` = `glider_bautek_astir` |
| `span_m` | 10,55 | паспорт (размер в паспорте не указан) |
| `area_m2` | 14,68 | паспорт (размер в паспорте не указан) |
| `nose_angle_deg` | 130 | паспорт |
| `root_chord_m / tip_chord_m` | 2,32 / 0,61 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,64 м² |
| `nose_forward_m` | 1,32 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 13 | паспорта нет — как у базы |
| `double_surface / lower_cover` | true / 0,85 | паспорт: двойная поверхность 85 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Угол носа 130°; удлинение 7,6. Заявленное качество 23 в сводке (страница производителя) — для 3D не используется, для физики не принимать.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Astir | 14,68 | 10,55 | 7,6 | 29 | 60–115 | 85 | 80 | 130 | — |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `nose_angle` = 130 ° — «Nose angle: 130 degr.»

### Источники

- https://www.bautek.com/english/hanggliders/astir/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Bautek|Astir||`).

### Открытые вопросы

- Число латов не найдено.
- Тип конструкции (мачтовая/безмачтовая) не установлен — определить по фото/описанию производителя и выбрать базу соответственно.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N18. Flugsport Skypoint Crossover (`fs_crossover`) — новая модель, приоритет P2

- **Модель:** Flugsport Skypoint Crossover; будущий файл `assets/models/glider_fs_crossover.glb`, запись `tools/blender/glider_params.json` → `wings.fs_crossover` (новая), конфиг `configs/wings/fs_crossover.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (DHV 2), двойная поверхность 82 %, историческое. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — предположение координатора (прямого подтверждения в найденных источниках нет; проверить по фото производителя).
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | fs_crossover | id модели; `out` = `glider_fs_crossover` |
| `span_m` | 9,9 | паспорт (опорный размер 14) |
| `area_m2` | 14 | паспорт, опорный размер 14 |
| `nose_angle_deg` | 127 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,36 / 0,62 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,98 м² |
| `nose_forward_m` | 1,34 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 9 | паспорт: верхних лат всего 18 ⇒ на сторону 9 |
| `double_surface / lower_cover` | true / 0,82 | паспорт: двойная поверхность 82 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Только карточка DHV.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Crossover 14 | 14 | 9,9 | — | 28,2 | — | 82 | 90 | — | 18 |
| Crossover 15 | 15 | 10,1 | — | 29,3 | — | 82 | 90 | — | 20 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 18  — «18 / 4»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_00)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_07)
- Номера DHV-сертификатов: DHV 01-0459-11, DHV 01-0460-11
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Flugsport Skypoint|Crossover||14`, `Flugsport Skypoint|Crossover||15`).

### Открытые вопросы

- Угол носа неизвестен.
- Угол носа в паспорте не найден — значение базы.
- Тип конструкции принят по предположению — подтвердить по фото производителя.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N19. Seedwings Spyder (`seed_spyder`) — новая модель, приоритет P2

- **Модель:** Seedwings Spyder; будущий файл `assets/models/glider_seed_spyder.glb`, запись `tools/blender/glider_params.json` → `wings.seed_spyder` (новая), конфиг `configs/wings/seed_spyder.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (DHV 2), двойная поверхность 82 %, историческое. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «The Austrian maker's topless is the Spyder» (https://www.delta-club-82.com/bible/494-hang-glider-spyder.htm).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2004.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Made with 7075 aluminum; Sail made by Pause Segel; Battens: 1 nose batten, 9 top battens with clip ends per side, 2 lower batten per side, 2 sprogs per side; No luff lines.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.sport` из `glider_params.json` (модель `glider_sport.glb`: 14 лат на сторону, угол носа 132°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | seed_spyder | id модели; `out` = `glider_seed_spyder` |
| `span_m` | 9,8 | паспорт (опорный размер 12.5) |
| `area_m2` | 12,5 | паспорт, опорный размер 12.5 |
| `nose_angle_deg` | 132 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,18 / 0,52 | форма базы (отношение хорд 0,239) пересчитана под паспортные размах и площадь; площадь в плане при этом 12,51 м² |
| `nose_forward_m` | 1,24 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 8 | паспорт: верхних лат всего 17 ⇒ на сторону 8 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,82 | паспорт: двойная поверхность 82 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Только карточка DHV 2005.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Spyder 12.5 | 12,5 | 9,8 | — | 28,5 | — | 82 | 90 | — | 17 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 17  — «Anzahl Latten  17»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_04)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- Номера DHV-сертификатов: DHV 01-0410-05
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Seedwings|Spyder||12.5`).

### Открытые вопросы

- Тип конструкции — по batch_c.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N20. Moyes Gecko (`moyes_gecko`) — новая модель, приоритет P1

- **Модель:** Moyes Gecko; будущий файл `assets/models/glider_moyes_gecko.glb`, запись `tools/blender/glider_params.json` → `wings.moyes_gecko` (новая), конфиг `configs/wings/moyes_gecko.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее/спортивное (DHV 3 по сертификату 2016), двойная поверхность 70–85 %. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «The kingpost folds forward with enough luff line slack to allow for a straightforward packing procedure.» (https://xcmag.com/news/moyes-gecko-intermediate-hang-glider/).
- **Заметки по виду (из выборки, проверять по первоисточнику):** 50/52mm leading edge in 7075 T6 aluminium, 62mm crossbars, carbon outboard dive strut retained inside double surface, 8 battens top, 2 battens under surface, si.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | moyes_gecko | id модели; `out` = `glider_moyes_gecko` |
| `span_m` | 9,7 | паспорт (опорный размер 155) |
| `area_m2` | 14,5 | паспорт, опорный размер 155 |
| `nose_angle_deg` | 124 | паспорт |
| `root_chord_m / tip_chord_m` | 2,50 / 0,66 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,52 м² |
| `nose_forward_m` | 1,42 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 8 | паспорт: верхних лат всего 17 ⇒ на сторону 8 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,85 | паспорт: двойная поверхность 85 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Есть размах с законцовками и двойная поверхность у корня/на конце (double_surface_coverage_root/tip), число верхних и нижних лат.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Gecko 155 | 14,5 | 9,7 | 6,48 | 29,5 | 55–86 | 85 | 90 | 124 | 17 |
| Gecko 170 | 15,8 | 10,07 | 6,42 | 33,1 | 70–110 | 80 | — | 124 | — |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `wingspan` = 9660 мм — «9.66 m / 31.7 ft.»
- `wingspan` = 9662,2 мм — «9.66 m / 31.7 ft.»
- `nose_angle` = 124 ° — «124 Degrees»
- `wing_area` = 14,4  — «14.4 m² / 155 sq. ft.»
- `wing_area` = 155  — «14.4 m² / 155 sq. ft.»
- `aspect_ratio` = 6,5  — «6.48»
- `battens_top_surface` = 8  — «Top Surface 8 / Under Surface 2»
- `battens_under_surface` = 2  — «Top Surface 8 / Under Surface 2»
- `double_surface_coverage_root` = None  — «70% (root) - 90% (tip)»
- `double_surface_coverage_tip` = None  — «70% (root) - 90% (tip)»
- `battens` = 8  — «Top Surface 8 / Under Surface 2»
- `battens` = 17  — «Anzahl Latten 17»

### Источники

- https://www.moyes.com.au/products/hang-gliders/gecko/specifications
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_02)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_09)
- Номера DHV-сертификатов: DHV 01-0490-16
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Moyes|Gecko||155`, `Moyes|Gecko||170`).

### Открытые вопросы

- Тип (мачтовый/безмачтовый) — batch_b.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N21. Wills Wing Sport 2 (`ww_sport2`) — новая модель, приоритет P2

- **Модель:** Wills Wing Sport 2; будущий файл `assets/models/glider_ww_sport2.glb`, запись `tools/blender/glider_params.json` → `wings.ww_sport2` (новая), конфиг `configs/wings/ww_sport2.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (USHPA III; DHV 2), мачтовое двухобшивочное 74 %, историческое. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «Kingposted design with internal sprogs for stability and a single reflex bridle per wing» (https://www.willswing.com/hang-gliders/sport-2/).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Designed for intermediate level pilots; Combination Bridle and Internal Stability System; Compatible with Litestream performance control bar; Light weight and good static balance.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_sport2 | id модели; `out` = `glider_ww_sport2` |
| `span_m` | 9,6 | паспорт (опорный размер 155) |
| `area_m2` | 14,4 | паспорт, опорный размер 155 |
| `nose_angle_deg` | 127 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,50 / 0,66 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,37 м² |
| `nose_forward_m` | 1,42 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 7 | паспорт: верхних лат всего 15 ⇒ на сторону 7 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,74 | паспорт: двойная поверхность 74 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Точки поляры WW есть (185 fpm @ 22 mph и 445 fpm @ 40 mph); удалён из игры пользователем 28.09.2026 (wings_lineup §3) — вернуть только по новому решению.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Sport 2 155 | 14,4 | 9,6 | — | 27 | — | 74 | 90 | — | 15 |
| Sport 2 135 | 12,5 | 8,9 | — | 25,3 | — | 74 | 85 | — | 13 |
| Sport 2 175 | — | — | — | — | — | — | 85 | — | — |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 15  — «15 / 5»

### Источники

- https://www.willswing.com/hang-glider-placard-specifications/
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_13)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_01)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_09)
- Номера DHV-сертификатов: DHV 01-0440-08, DHV 01-0478-13
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Sport 2||155`, `Wills Wing|Sport 2||135`, `Wills Wing|Sport 2||175`).

### Открытые вопросы

- Была убрана из игры по решению пользователя (28.09.2026) — сверить, нужна ли вообще.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N22. Wills Wing Super Sport (`ww_super_sport`) — новая модель, приоритет P2

- **Модель:** Wills Wing Super Sport; будущий файл `assets/models/glider_ww_super_sport.glb`, запись `tools/blender/glider_params.json` → `wings.ww_super_sport` (новая), конфиг `configs/wings/ww_super_sport.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (USHPA III), историческое. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** неизвестен — определить по фото производителя до начала работы.
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** с 1991 по 1997; преемственность: Replaced by Ultra Sport.
- **Заметки по виду (из выборки, проверять по первоисточнику):** HP AT airfoil and airframe technology; Seamless drawn aircraft quality 7075 airframe; Faired wingtips and nosecone; Premium sailcloth options with pilot-selectable colors.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.magic` из `glider_params.json` (модель `glider_magic.glb`: 11 лат на сторону, угол носа 124°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_super_sport | id модели; `out` = `glider_ww_super_sport` |
| `span_m` | 9,96 | паспорт (опорный размер 153) |
| `area_m2` | 14,21 | паспорт, опорный размер 153 |
| `nose_angle_deg` | 124 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,27 / 0,71 | форма базы (отношение хорд 0,314) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,21 м² |
| `nose_forward_m` | 1,29 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 11 | паспорта нет — как у базы |
| `double_surface / lower_cover` | true / 0,6 | паспорта нет — как у базы |
| `crossbar_u` | 0,57 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4595`, `k_t = 0,5405` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Паспорт: площадь, размах, удлинение, масса, плакат; угла носа, числа латов нет.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Super Sport 153 | 14,21 | 9,96 | 7 | 28,1 | 70–113 | — | 93 | — | — |
| Super Sport 143 | 13,29 | 9,45 | 6,7 | 25,9 | 57–95 | — | 93 | — | — |
| Super Sport 163 | 15,14 | 10,46 | 7,3 | 29,9 | 79–125 | — | 93 | — | — |

### Источники

- https://www.willswing.com/hang-gliders/archive/super-sport/
- https://www.willswing.com/hang-glider-placard-specifications/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Super Sport||153`, `Wills Wing|Super Sport||143`, `Wills Wing|Super Sport||163`).

### Открытые вопросы

- Тип конструкции — batch_a.
- Угол носа в паспорте не найден — значение базы.
- Тип конструкции (мачтовая/безмачтовая) не установлен — определить по фото/описанию производителя и выбрать базу соответственно.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N23. Wills Wing Ultra Sport (`ww_ultra_sport`) — новая модель, приоритет P2

- **Модель:** Wills Wing Ultra Sport; будущий файл `assets/models/glider_ww_ultra_sport.glb`, запись `tools/blender/glider_params.json` → `wings.ww_ultra_sport` (новая), конфиг `configs/wings/ww_ultra_sport.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (USHPA III), историческое. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «Kingpost design» (https://www.willswing.com/hang-gliders/archive/ultra-sport/).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 1996 по 2003; преемственность: Succeeded by T2/T2C for competition and Sport 2 line for recreational use.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Complete redesign from Super Sport predecessor; Incorporated technology from Cross Country (hardware) and Fusion (airfoil) models; Intermediate-advanced move-up model; Notable low stall speed and exceptional climb characteristics.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.magic` из `glider_params.json` (модель `glider_magic.glb`: 11 лат на сторону, угол носа 124°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_ultra_sport | id модели; `out` = `glider_ww_ultra_sport` |
| `span_m` | 9,96 | паспорт (опорный размер 147) |
| `area_m2` | 13,66 | паспорт, опорный размер 147 |
| `nose_angle_deg` | 124 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,18 / 0,68 | форма базы (отношение хорд 0,314) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,63 м² |
| `nose_forward_m` | 1,24 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 11 | паспорта нет — как у базы |
| `double_surface / lower_cover` | true / 0,6 | паспорта нет — как у базы |
| `kingpost_m` | 1,2 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,57 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4595`, `k_t = 0,5405` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Паспорт: площадь, размах, удлинение, масса, плакат, точки поляры.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Ultra Sport 147 | 13,66 | 9,96 | 7,25 | 29,5 | 68–113 | — | 85 | — | — |
| Ultra Sport 135 | 12,54 | 9,3 | 6,9 | 27,2 | 57–95 | — | 85 | — | — |
| Ultra Sport 166 | 15,42 | 10,41 | 7 | 31,8 | 79–129 | — | 85 | — | — |

### Источники

- https://www.willswing.com/hang-gliders/archive/ultra-sport/
- https://www.willswing.com/hang-glider-placard-specifications/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Ultra Sport||147`, `Wills Wing|Ultra Sport||135`, `Wills Wing|Ultra Sport||166`).

### Открытые вопросы

- Тип конструкции — batch_a.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N24. Wills Wing Spectrum (`ww_spectrum`) — новая модель, приоритет P2

- **Модель:** Wills Wing Spectrum; будущий файл `assets/models/glider_ww_spectrum.glb`, запись `tools/blender/glider_params.json` → `wings.ww_spectrum` (новая), конфиг `configs/wings/ww_spectrum.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** начальное (USHPA II Novice), историческое. Предлагаемая группа игры: `trainer` (`configs/wing_groups.json`).
- **Конструкция:** неизвестен — определить по фото производителя до начала работы.
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** с 1990 по 2000; преемственность: Replaced by Falcon, Eagle, and Ultra Sport.
- **Заметки по виду (из выборки, проверять по первоисточнику):** High-performance entry-level glider; 7075 aluminum alloy airframe and battens; Faired wingtips for drag reduction; Optional streamline downtubes and speedbar.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.training` из `glider_params.json` (модель `glider_training.glb`: 8 лат на сторону, угол носа 122°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_spectrum | id модели; `out` = `glider_ww_spectrum` |
| `span_m` | 10,36 | паспорт (опорный размер 165) |
| `area_m2` | 15,33 | паспорт, опорный размер 165 |
| `nose_angle_deg` | 121 | паспорт |
| `root_chord_m / tip_chord_m` | 2,29 / 0,81 | форма базы (отношение хорд 0,353) пересчитана под паспортные размах и площадь; площадь в плане при этом 15,34 м² |
| `nose_forward_m` | 1,3 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 8 | паспорта нет — как у базы |
| `double_surface / lower_cover` | false / 0,14 | паспорта нет — как у базы |
| `crossbar_u` | 0,55 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Угол носа 120–121°; остального нет.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Spectrum 165 | 15,33 | 10,36 | 7 | 27,2 | 64–109 | — | 85 | 121 | — |
| Spectrum 144 | 13,38 | 9,45 | 6,7 | 24,5 | 50–95 | — | 85 | 120 | — |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `nose_angle` = 121 ° — «Nose Angle 121°»

### Источники

- https://www.willswing.com/hang-gliders/archive/spectrum/
- https://www.willswing.com/hang-glider-placard-specifications/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Spectrum||165`, `Wills Wing|Spectrum||144`).

### Открытые вопросы

- Тип конструкции — batch_a.
- Тип конструкции (мачтовая/безмачтовая) не установлен — определить по фото/описанию производителя и выбрать базу соответственно.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N25. Wills Wing T2 / T2C (`ww_t2c`) — новая модель, приоритет P1

- **Модель:** Wills Wing T2 / T2C; будущий файл `assets/models/glider_ww_t2c.glb`, запись `tools/blender/glider_params.json` → `wings.ww_t2c` (новая), конфиг `configs/wings/ww_t2c.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** соревновательное безмачтовое (DHV 3; USHPA IV Advanced), VG. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое — предположение координатора (прямого подтверждения в найденных источниках нет; проверить по фото производителя).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2013; преемственность: Full competition version of T2.
- **Заметки по виду (из выборки, проверять по первоисточнику):** All mylar top surface sail with special UV-film laminate sail material; Carbon-kevlar leading edge pocket inserts; Ergonomically-designed carbon streamlined basetube.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.sport` из `glider_params.json` (модель `glider_sport.glb`: 14 лат на сторону, угол носа 132°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_t2c | id модели; `out` = `glider_ww_t2c` |
| `span_m` | 9,8 | паспорт (опорный размер 144) |
| `area_m2` | 13,4 | паспорт, опорный размер 144 |
| `nose_angle_deg` | 129,5 | паспорт: диапазон 127–132° (VG), берём середину |
| `root_chord_m / tip_chord_m` | 2,33 / 0,56 | форма базы (отношение хорд 0,239) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,39 м² |
| `nose_forward_m` | 1,28 | паспорт: петля подвеса от линии носовых болтов 1264–1302 мм (49,75–51,25 in), середина |
| `battens_per_side` | 11 | паспорт: верхних лат всего 23 ⇒ на сторону 11 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,92 | паспорт: двойная поверхность 92 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,59 | паспорт: поперечина 2949 мм от центрального штыря (на киле в 806 мм от носа) до кромки ⇒ крепление на расстоянии 3,2 м от носа по кромке длиной ≈ 5,42 м |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Есть всё для корпуса: диаметр передней кромки, хорды в 3 футах от конца (`sail_chord_3ft_*`), диаметр поперечины, длина поперечины, киль→центр поперечины (`keel_to_crossbar_center`), киль→петля подвеса (`keel_to_hang_loop`), диаметры тросов — использовать для `crossbar_u`, `nose_forward_m`, радиусов труб.
- T2 и T2C — записи паспорта с одинаковыми размерами (144: 13,4 м², 9,8 м; 154: 14,3 м², 10,2 м) — одна 3D-модель на обе; на странице T2C упомянуты латы 12 мм вместо стандартных 10 мм (на форму не влияет).

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| T2C 144 | 13,4 | 9,8 | 7,3 | 33,4 | 73–107 | 92 | 85 | 127–132 | 23 |
| T2C 136 | 12,6 | 9,6 | 7,3 | 32,3 | 68–95 | 92 | 85 | 127–132 | 21 |
| T2C 154 | 14,3 | 10,23 | 7,4 | 34,9 | 84–129 | 92 | 90 | 127–132 | 25 |
| T2 144 | 13,38 | 9,85 | 7,3 | 32,3 | 73–107 | 92 | 85 | 127–132 | — |
| T2 154 | 14,31 | 10,21 | 7,4 | 33,5 | 84–129 | 92 | 85 | 127–132 | — |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `leading_edge_dia_front` = 60 мм — «The front leading edge is 60mm (2.36") over sleeved»
- `leading_edge_dia_front` = 62 мм — «sleeved with 62mm (2.44") at the crossbar junction»
- `rear_leading_edge_diameter_at_sprogs` = 52 мм — «with 52mm (2.05") at the outer sprog attachment point (T2C)»
- `crossbar_overall_length` = 2948,9 мм — «Overall pin to pin length from hole at leading edge bracket attachment to center of load b»
- `crossbar_dia` = 82,5 мм — «Largest outside dimension 3.25»
- `keel_to_crossbar_center` = 806,5 мм — «distance from the line joining the leading edge nose bolts to: The center of the xbar load»
- `keel_to_hang_loop` = 1263,7 мм — «distance to: The pilot hang loop 49.75 - 51.25»
- `sail_chord_3ft_outboard` = 1651 мм — «Chord lengths at 3 ft outboard of centerline 65»
- `sail_chord_3ft_inboard_tip` = 1143 мм — «3 ft inboard of tip 45»
- `sail_span_vgt` = 9893,3 мм — «Span (extreme tip to tip) 389.5 (VGT)»
- `batten_diameter` = 12 мм — «12mm 7075 Battens»
- `front_rear_wire_diameter` = 2 мм — «5/64 (2mm) 1×19 front-rear wires»
- `sidewire_diameter` = 2,4 мм — «3/32 1×19 sidewires standard»
- `sprog_cable_diameter` = 3,2 мм — «Carbon sprogs with 1/8 inch cables»
- `nose_angle` = 127 ° — «Nose Angle (deg) 127-132»
- `nose_angle` = 132 ° — «Nose Angle (deg) 127-132»
- `battens` = 12  — «12mm 7075 Battens which are both 1 lb. lighter and stiffer than standard 10mm battens»
- `battens` = 23  — «23 / 6»

### Источники

- http://willswing.com/wp-content/uploads/manuals/T2_5th_September_2012.pdf
- https://www.willswing.com/hang-gliders/t2c/
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_01)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_13)
- https://www.willswing.com/hang-glider-placard-specifications/
- Номера DHV-сертификатов: DHV 01-0471-13, DHV 01-0472-13, DHV 01-0439-08
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|T2C||144`, `Wills Wing|T2C||136`, `Wills Wing|T2C||154`, `Wills Wing|T2||144`, `Wills Wing|T2||154`).

### Открытые вопросы

- Ориентир качества: класс T2C по LK8000 (13,6 на 47,5 км/ч) — для конфига, не для 3D.
- Тип конструкции принят по предположению — подтвердить по фото производителя.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N26. Wills Wing T3 (`ww_t3`) — новая модель, приоритет P1

- **Модель:** Wills Wing T3; будущий файл `assets/models/glider_ww_t3.glb`, запись `tools/blender/glider_params.json` → `wings.ww_t3` (новая), конфиг `configs/wings/ww_t3.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** соревновательное безмачтовое (USHPA IV Advanced), VG, двойная поверхность 92 %. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое — предположение координатора (прямого подтверждения в найденных источниках нет; проверить по фото производителя).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2020.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Bearing tips system for extraordinary improvement in handling and control authority; UV-film laminate top surface with Technora laminates on Race and Team editions; ACLER (Advanced Composite Leading Edge Reinforcement) - Kevlar and carbon fiber molded inserts; Carbon fiber over-molded battens on longest 4 battens.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.sport` из `glider_params.json` (модель `glider_sport.glb`: 14 лат на сторону, угол носа 132°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_t3 | id модели; `out` = `glider_ww_t3` |
| `span_m` | 10,06 | паспорт (опорный размер 144) |
| `area_m2` | 13,38 | паспорт, опорный размер 144 |
| `nose_angle_deg` | 127 | паспорт |
| `root_chord_m / tip_chord_m` | 2,27 / 0,54 | форма базы (отношение хорд 0,239) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,36 м² |
| `nose_forward_m` | 1,29 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 14 | паспорта нет — как у базы |
| `double_surface / lower_cover` | true / 0,92 | паспорт: двойная поверхность 92 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Актуальная модель; угол носа 127°, удлинение 7,6, размах 10,06 м при площади 13,38 м² (144).

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| T3 144 | 13,38 | 10,06 | 7,6 | 32,2 | 73–107 | 92 | 85 | 127 | — |
| T3 136 | 12,63 | 9,78 | 7,6 | 31,3 | 68–95 | 92 | 85 | 127 | — |
| T3 154 | 14,31 | 10,42 | 7,6 | 33,1 | 84–129 | 92 | 85 | 127 | — |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `nose_angle` = 127 ° — «Nose Angle (deg) 127-132»

### Источники

- https://www.willswing.com/hang-glider-placard-specifications/
- https://www.willswing.com/hang-gliders/t3/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|T3||144`, `Wills Wing|T3||136`, `Wills Wing|T3||154`).

### Открытые вопросы

- Число латов на странице T3 не извлечено — по базе.
- Тип конструкции принят по предположению — подтвердить по фото производителя.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N27. Moyes Litespeed RX (`moyes_litespeed_rx`) — новая модель, приоритет P1

- **Модель:** Moyes Litespeed RX; будущий файл `assets/models/glider_moyes_litespeed_rx.glb`, запись `tools/blender/glider_params.json` → `wings.moyes_litespeed_rx` (новая), конфиг `configs/wings/moyes_litespeed_rx.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** соревновательное безмачтовое (DHV 3), VG. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «The Litespeed RX is a topless competition glider with a small surface and a smaller a-frame, meaning it does not have a kingpost» (https://moyes.com.au/52-hang-gliders/litespeed-rx).
- **Заметки по виду (из выборки, проверять по первоисточнику):** Topless, fourth generation, small surface, smaller a-frame, carbon fibre cross bars, pre-impregnated carbon fibre spars cured at 120°C for 1.5 hours, roll press.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.sport` из `glider_params.json` (модель `glider_sport.glb`: 14 лат на сторону, угол носа 132°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | moyes_litespeed_rx | id модели; `out` = `glider_moyes_litespeed_rx` |
| `span_m` | 10,27 | паспорт (опорный размер 4) |
| `area_m2` | 13,9 | паспорт, опорный размер 4 |
| `nose_angle_deg` | 127,5 | паспорт: диапазон 125–130° (VG), берём середину |
| `root_chord_m / tip_chord_m` | 2,31 / 0,55 | форма базы (отношение хорд 0,239) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,88 м² |
| `nose_forward_m` | 1,35 | паспорт: положение ЦТ от носа киля 1354 мм |
| `battens_per_side` | 11 | паспорт: верхних лат всего 23 ⇒ на сторону 11 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,92 | паспорт: двойная поверхность 92 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Положение ЦТ от носа киля 1343–1353 мм — использовать как `nose_forward_m`; «Mainsail 23 + Undersurface 6» лат.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Litespeed RX 4 | 13,9 | 10,27 | 7,6 | 34,2 | 75–115 | 92 | 90 | 125–130 | 23 |
| Litespeed RX 3 | 12,8 | 9,77 | 7,4 | 32,4 | 59–89 | 92 | 90 | 125–130 | 21 |
| Litespeed RX 3.5 | 13,5 | 10,07 | 7,5 | 33,6 | 68–108 | 92 | 90 | 125–130 | 23 |
| Litespeed RX 5 | 14,8 | 10,4 | 7,3 | 34,3 | 85–119 | 92 | 90 | 125–130 | 23 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `cg_front_of_keel` = 1353 мм — «C of G Front of Keel 1353 mm»
- `cg_front_of_keel` = 1353,8 мм — «C of G Front of Keel 53.3 inches»
- `nose_angle` = 130 ° — «Nose Angle (tight-loose) 130-125 deg.»
- `nose_angle` = 125 ° — «Nose Angle (tight-loose) 130-125 deg.»
- `battens` = 23  — «Number of Battens: Mainsail 23»
- `battens` = 6  — «Number of Battens: Undersurface 6»

### Источники

- https://www.moyes.com.au/products/hang-gliders/litespeed-rx/specifications
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_01)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_02)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_09)
- Номера DHV-сертификатов: DHV 01-0468-13, DHV 01-0481-15, DHV 01-0469-13, DHV 01-0479-15, DHV 01-0467-13, DHV 01-0480-15, DHV 01-0482-15
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Moyes|Litespeed RX||4`, `Moyes|Litespeed RX||3`, `Moyes|Litespeed RX||3.5`, `Moyes|Litespeed RX||5`).

### Открытые вопросы

- Отличие формы RX от RS 4 (существующая модель `sport`) в паспортах не описано: 3D-модель на базе `sport`, различия только в размерах/числе лат.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N28. Moyes Litespeed S (`moyes_litespeed_s`) — новая модель, приоритет P2

- **Модель:** Moyes Litespeed S; будущий файл `assets/models/glider_moyes_litespeed_s.glb`, запись `tools/blender/glider_params.json` → `wings.moyes_litespeed_s` (новая), конфиг `configs/wings/moyes_litespeed_s.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** спортивное безмачтовое (DHV 3), 2005, историческое. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «The entire family of gliders are 'topless' designs, lacking a kingpost and upper rigging.» (https://en.wikipedia.org/wiki/Moyes_Litespeed).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Topless, pre-impregnated carbon fibre spars, 8 internal cloth ribs restricting under surface, internal ribs cut to specific airfoil for desired camber, 6 unders.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.sport` из `glider_params.json` (модель `glider_sport.glb`: 14 лат на сторону, угол носа 132°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | moyes_litespeed_s | id модели; `out` = `glider_moyes_litespeed_s` |
| `span_m` | 10 | паспорт (опорный размер 4) |
| `area_m2` | 13,7 | паспорт, опорный размер 4 |
| `nose_angle_deg` | 130 | паспорт |
| `root_chord_m / tip_chord_m` | 2,34 / 0,56 | форма базы (отношение хорд 0,239) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,71 м² |
| `nose_forward_m` | 1,35 | паспорт: положение ЦТ от носа киля 1354 мм |
| `battens_per_side` | 11 | паспорт: верхних лат всего 23 ⇒ на сторону 11 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,92 | паспорт: двойная поверхность 92 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Руководство: диаметр киля 42 мм, угол носа 130–132°, ЦТ 1343–1370 мм.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Litespeed S 4 | 13,7 | 10 | 7,3 | 36 | 68–109 | 92 | 90 | 130 | 23 |
| Litespeed S 3.5 | 13,4 | 9,6 | 7,5 | 34 | 68–109 | 92 | 90 | 130 | 23 |
| Litespeed S 4.5 | 14,1 | 10,4 | 7,6 | 35 | 75–120 | 92 | 90 | 130 | 23 |
| Litespeed S 5 | 14,59 | 10,38 | 7,4 | 34,5 | 75–120 | — | 85 | 130 | 23 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `cg_front_of_keel` = 1353 мм — «C of G Front of Keel 1353 mm»
- `cg_front_of_keel` = 1353,8 мм — «C of G Front of Keel 53.3 inches»
- `keel_dia` = 42 мм — «Outer diameter of keel (42mm)»
- `battens` = 23  — «Number of Battens: 23»
- `mainsail_battens` = 6  — «Mainsail 6»
- `nose_angle` = 130 ° — «Nose Angle 130 to 132 deg»
- `battens` = 23  — «Anzahl Latten 23»

### Источники

- https://www.delta-club-82.com/bible/manuels/litespeed-S.pdf
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_03)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_10)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- Номера DHV-сертификатов: DHV 01-0403-05, DHV 01-0404-05, DHV 01-0405-05
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Moyes|Litespeed S||4`, `Moyes|Litespeed S||3.5`, `Moyes|Litespeed S||4.5`, `Moyes|Litespeed S||5`).

### Открытые вопросы

- нет

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N29. Moyes Litesport (`moyes_litesport`) — новая модель, приоритет P1

- **Модель:** Moyes Litesport; будущий файл `assets/models/glider_moyes_litesport.glb`, запись `tools/blender/glider_params.json` → `wings.moyes_litesport` (новая), конфиг `configs/wings/moyes_litesport.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** средне-спортивное (класс на странице не указан). Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «The company builds a derivative aircraft with a kingpost, the Litesport.» (http://moyesusa.com/products/litesportspecs.html).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Kingpost with VG system, 7075 aluminum tubing, double-surface wing.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | moyes_litesport | id модели; `out` = `glider_moyes_litesport` |
| `span_m` | 9,6 | паспорт (опорный размер 4) |
| `area_m2` | 13,8 | паспорт, опорный размер 4 |
| `nose_angle_deg` | 127 | паспорт |
| `root_chord_m / tip_chord_m` | 2,40 / 0,63 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,78 м² |
| `nose_forward_m` | 1,39 | паспорт: положение ЦТ от носа киля 1390 мм |
| `battens_per_side` | 13 | паспорт: верхних лат всего 27 ⇒ на сторону 13 (нечётное число: одна центральная лата у киля не считается) |
| `double_surface / lower_cover` | true / 0,8 | паспорта нет — как у базы |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Запись «Litesport 3/4»: угол носа 127°, удлинение 6,7–6,8, число латов 27 (вероятно, с нижними).

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Litesport 4 | 13,8 | 9,6 | 6,7 | 31,8 | 68–109 | — | 85 | 127 | 27 |
| Litesport 3 | 13 | 9,4 | 6,8 | 30 | 65–85 | — | 85 | 127 | 27 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `cg_front_of_keel` = 1390 мм — «Centre of Gravity (Front of Keel) ** 1390 mm»
- `nose_angle` = 127 ° — «Nose Angle 127 - 129 degrees»
- `battens` = 27  — «Number of Battens Top 21 Bottom 6»

### Источники

- https://www.moyes.com.au/products/hang-gliders/litesport/specifications
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Moyes|Litesport||4`, `Moyes|Litesport||3`).

### Открытые вопросы

- Тип (мачта/топлесс) — batch_b; если мачтовое — основа `laminar`.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N30. Aeros Combat C (и DesignProducts Combat C AC) (`aeros_combat_c`) — новая модель, приоритет P1

- **Модель:** Aeros Combat C (и DesignProducts Combat C AC); будущий файл `assets/models/glider_aeros_combat_c.glb`, запись `tools/blender/glider_params.json` → `wings.aeros_combat_c` (новая), конфиг `configs/wings/aeros_combat_c.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** соревновательное безмачтовое (DHV 3), 2016–. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «Topless (no kingpost). The glider features 'three tubes' in the leading edge design.» (https://aeros.com.ua/combat_c).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Topless, requires horizontal stabilizer (tail) for safe flight, elliptical shape carbon leading edge tubes tapered along entire length, carbon fiber main and ou.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.combat` из `glider_params.json` (модель `glider_combat.glb`: 16 лат на сторону, угол носа 130°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | aeros_combat_c | id модели; `out` = `glider_aeros_combat_c` |
| `span_m` | 10,3 | паспорт (опорный размер 12.7) |
| `area_m2` | 12,7 | паспорт, опорный размер 12.7 |
| `nose_angle_deg` | 130 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,13 / 0,48 | форма базы (отношение хорд 0,227) пересчитана под паспортные размах и площадь; площадь в плане при этом 12,69 м² |
| `nose_forward_m` | 1,21 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 12 | паспорт: верхних лат всего 24 ⇒ на сторону 12 |
| `double_surface / lower_cover` | true / 0,9 | паспорт: двойная поверхность 90 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Combat C AC (DesignProducts) — тот же размах/площадь по размерам, отличается вес: одна 3D-модель на обе.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Combat C 12.7 | 12,7 | 10,3 | — | 31,3 | — | 90 | 90 | — | 24 |
| Combat C 12.4 | 12,4 | 10 | — | 30,4 | — | 90 | 90 | — | 24 |
| Combat C 13.5 | 13,5 | 10,7 | — | 32,5 | — | 90 | 90 | — | 24 |
| Combat C AC 12.7 | 12,7 | 10,3 | — | 30,6 | — | 90 | 90 | — | 24 |
| Combat C AC 13 | 13 | 10,7 | — | 30,2 | — | 90 | 90 | — | 24 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 24  — «Anzahl Latten 24»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_02)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_10)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_03)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_09)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_04)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- Номера DHV-сертификатов: DHV 01-0489-16, DHV 01-0500-21, DHV 01-0492-17, DHV 01-0503-23, DHV 01-0506-24
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Aeros|Combat C||12.7`, `Aeros|Combat C||12.4`, `Aeros|Combat C||13.5`, `DesignProducts|Combat C AC||12.7`, `DesignProducts|Combat C AC||13`).

### Открытые вопросы

- Связь DesignProducts↔Aeros — batch_c.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N31. Aeros Combat L (`aeros_combat_l`) — новая модель, приоритет P2

- **Модель:** Aeros Combat L; будущий файл `assets/models/glider_aeros_combat_l.glb`, запись `tools/blender/glider_params.json` → `wings.aeros_combat_l` (новая), конфиг `configs/wings/aeros_combat_l.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** соревновательное безмачтовое (DHV 3), 2005–2008, историческое. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «The Combat series features cable-braced wings without a kingpost and upper rigging. These are topless design hang gliders.» (https://forum.hanggliding.org/viewtopic.php?t=34880).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** с 2003.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Topless, cable-braced wings without kingpost, aspect ratio 7.8-8.06, glider weight 34-36 kg.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.combat` из `glider_params.json` (модель `glider_combat.glb`: 16 лат на сторону, угол носа 130°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | aeros_combat_l | id модели; `out` = `glider_aeros_combat_l` |
| `span_m` | 10,35 | паспорт (опорный размер 13) |
| `area_m2` | 13,7 | паспорт, опорный размер 13 |
| `nose_angle_deg` | 130 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,28 / 0,52 | форма базы (отношение хорд 0,227) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,68 м² |
| `nose_forward_m` | 1,3 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 12 | паспорт: верхних лат всего 24–26 ⇒ на сторону 12 |
| `double_surface / lower_cover` | true / 0,9 | паспорт: двойная поверхность 90 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Почти идентично Combat GT по размерам.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Combat L 13 | 13,7 | 10,35 | — | 36,3 | — | 90 | 90 | — | 24–26 |
| Combat L 12 | 12,8 | 10 | — | 35,8 | — | 90 | 90 | — | 26 |
| Combat L 14 | 14,2 | 10,7 | — | 38,5 | — | 90 | 90 | — | 24–26 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 26  — «26 / 6»
- `battens` = 24  — «Anzahl Latten  24»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_00)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_04)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_05)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_07)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_13)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- Номера DHV-сертификатов: DHV 01-0413-05, DHV 01-0431-08, DHV 01-0451-10, DHV 01-0430-08, DHV 01-0450-10, DHV 01-0414-06, DHV 01-0432-08, DHV 01-0452-10
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Aeros|Combat L||13`, `Aeros|Combat L||12`, `Aeros|Combat L||14`).

### Открытые вопросы

- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N32. Icaro Laminar (Zero 9 / Zero 7 / Z8) (`icaro_laminar_z9`) — новая модель, приоритет P1

- **Модель:** Icaro Laminar (Zero 9 / Zero 7 / Z8); будущий файл `assets/models/glider_icaro_laminar_z9.glb`, запись `tools/blender/glider_params.json` → `wings.icaro_laminar_z9` (новая), конфиг `configs/wings/icaro_laminar_z9.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** соревновательное безмачтовое (DHV 3), VG, 94–96 %. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «Topless design. The hang glider's modern age began in 1996 with the introduction of topless gliders» (https://www.icaro2000.com/Products/Hanggliders/Laminar/Laminar.htm).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 1994; преемственность: Predecessor to MastR (MastR is Laminar with kingpost added).
- **Заметки по виду (из выборки, проверять по первоисточнику):** Six removable mini-battens on trailing edge (under 15 grams total); Ergal 7075 aluminum frame tubes (aerospace-grade alloy); Circular-section crossbar with carbon lamination; Compensated Twist Tips system allowing differential movement.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.combat` из `glider_params.json` (модель `glider_combat.glb`: 16 лат на сторону, угол носа 130°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | icaro_laminar_z9 | id модели; `out` = `glider_icaro_laminar_z9` |
| `span_m` | 10,02 | паспорт (опорный размер 13.7) |
| `area_m2` | 13,83 | паспорт, опорный размер 13.7 |
| `nose_angle_deg` | 132 | паспорт |
| `root_chord_m / tip_chord_m` | 2,38 / 0,54 | форма базы (отношение хорд 0,227) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,82 м² |
| `nose_forward_m` | 1,35 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 12 | паспорт: верхних лат всего 24 ⇒ на сторону 12 |
| `double_surface / lower_cover` | true / 0,94 | паспорт: двойная поверхность 94 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Не путать с существующей мачтовой `laminar` (Easy 14): это топлесс-Laminar 2008–2022.
- Из PDF: угол носа 132° (12.6, 13.2, 13.7) и 134° (14.1, 14.8), 22–26 верхних лат + 4–6 нижних, размах без законцовок и с ними (например 13.7: 9,99 и 10,28 м), длина троса поперечины, высоты лат/концов (допуски монтажа) — последнее для 3D не нужно.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Laminar 13.7 | 13,83 | 10,02 | 7,24 | 30,9 | 80–95 | 94 | 90 | 132 | 24 |
| Laminar 12.6 | 12,46 | 9,58 | 7,36 | 28,5 | 55–75 | 96 | 90 | 132 | 22 |
| Laminar 13.2 | 13,22 | 10,02 | 7,57 | 30,9 | 75–90 | 96 | 90 | 132 | 24 |
| Laminar 14.1 | 14,1 | 10,7 | 7,72 | 33,6 | 92–102 | 96 | 90 | 134 | 26 |
| Laminar 14.8 | 14,78 | 10,48 | 7,38 | 33,1 | 100–110 | 94 | 90 | 134 | 26 |
| Laminar Zero 9 13.7 | 13,7 | 10,1 | — | 33,6 | — | 94 | 90 | — | 24 |
| Laminar Zero 7 14.2 | 14,2 | 10,33 | — | 36,5 | — | 94 | 90 | — | 24 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `crossbar_cable_length` = 730 мм — «13.7 LAMINAR / 13.7 LAMINAR RF 730 / 720 mm»
- `batten_height_pos1_carbon` = -53 мм — «13.7 LAMINAR Carbon Battens Position 1 -53 ± 10»
- `batten_height_pos2_carbon` = -68 мм — «13.7 LAMINAR Carbon Battens Position 2 -68 ± 10»
- `wingtip_height_pos3_carbon` = -263 мм — «13.7 LAMINAR Carbon Battens Position 3 -263 ± 10»
- `batten_height_pos1_aluminum` = -38 мм — «13.7 LAMINAR Aluminum Battens Position 1 -38 ± 10»
- `batten_height_pos2_aluminum` = -53 мм — «13.7 LAMINAR Aluminum Battens Position 2 -53 ± 10»
- `wingtip_height_pos3_aluminum` = -256 мм — «13.7 LAMINAR Aluminum Battens Position 3 -256 ± 10»
- `nose_angle` = 132 ° — «Nose Angle deg 132»
- `battens` = 30  — «Battens (upper + lower) n 24+6»
- `wing_surface` = 148,4  — «Wing Surface sq ft 148.4»
- `wing_surface_with_wingtips` = 150,4  — «Wing Surface with wingtips sq ft 150.4»
- `wingspan` = 9997,4 мм — «Wing Span ft 32.8»
- `wingspan_with_tips` = 10271,8 мм — «Wing Span with wingtips ft 33.7»
- `aspect_ratio_with_wingtips` = 7,6  — «Aspect Ratio without/with wingtips 7.24 – 7.56»
- `wing_surface` = 13,8  — «Wing Surface m^2 13.79»
- `wing_surface_with_wingtips` = 14  — «Wing Surface with wingtips m^2 13.97»
- `wingspan` = 9990 мм — «Wing Span m 9.99»
- `wingspan_with_tips` = 10280 мм — «Wing Span with wingtips m 10.28»

### Источники

- https://www.icaro2000.com/Products/Manuals/Laminar%202011-3-En.docx.pdf
- https://www.icaro2000.com/Products/Hanggliders/Laminar/Laminar 2022 Imperial data.pdf
- https://www.icaro2000.com/Products/Hanggliders/Laminar/Laminar 2022 Metric data.pdf
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_01)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_06)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_13)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_04)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_11)
- Номера DHV-сертификатов: DHV 01-0476-13, DHV 01-0437-08, DHV 01-0407-05
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Icaro|Laminar||13.7`, `Icaro|Laminar||12.6`, `Icaro|Laminar||13.2`, `Icaro|Laminar||14.1`, `Icaro|Laminar||14.8`, `Icaro|Laminar|Zero 9|13.7`, `Icaro|Laminar|Zero 7|14.2`).

### Открытые вопросы

- Законцовки (wingtips) у Laminar — отдельные съёмные элементы; в 3D-модели не выделять.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N33. Bautek Fizz (`bautek_fizz`) — новая модель, приоритет P1

- **Модель:** Bautek Fizz; будущий файл `assets/models/glider_bautek_fizz.glb`, запись `tools/blender/glider_params.json` → `wings.bautek_fizz` (новая), конфиг `configs/wings/bautek_fizz.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее/спортивное (DHV 3), мачтовое («classic and time tested kingpost construction», точка подвеса на кингпосте), двойная поверхность 90 %, VG. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «The Fizz has the classic and time tested kingpost construction, without luff-lines, but with sprogs inside the double sail» (https://www.bautek.com/english/hanggliders/fizz/).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2006; преемственность: Followed Kite model (2006); Fizz SE arrived 2017.
- **Заметки по виду (из выборки, проверять по первоисточнику):** 34-foot span; 7.7 aspect ratio; Radial wingtips with winglets; Spring-loaded side wires for shock absorption.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | bautek_fizz | id модели; `out` = `glider_bautek_fizz` |
| `span_m` | 10,41 | паспорт (размер в паспорте не указан) |
| `area_m2` | 14,1 | паспорт (размер в паспорте не указан) |
| `nose_angle_deg` | 130 | паспорт |
| `root_chord_m / tip_chord_m` | 2,26 / 0,60 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,11 м² |
| `nose_forward_m` | 1,28 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 12 | паспорт: верхних лат всего 24 ⇒ на сторону 12 |
| `double_surface / lower_cover` | true / 0,9 | паспорт: двойная поверхность 90 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Есть: трубы передней кромки 50–52 мм, поперечина 60–62 мм, киль 50–48 мм (толщина стенки 0,9 мм), тросы Ø2,5 мм, 24 верхних + 6 нижних лат (Ø10 мм CFRP в версии SE), угол носа 130°, радиальные законцовки с винглетами (стеклопластик), профилированный алюминиевый спидбар (опция), опциональный киль-стабилизатор — использовать для каркаса и трапеции.
- Точка подвеса «on kingpost» — подвес над кингпостом: проверить по фото, `nose_forward_m` — по базе.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Fizz | 14,1 | 10,41 | 7,7 | 31,5 | 60–118 | 90 | 90 | 130 | 24 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `leading_edge_dia_front` = 50-52  — «wing tubes are 50‐52 mm»
- `crossbar_dia` = 60-62  — «crossbar is 60‐62 mm»
- `keel_dia` = 50-48  — «keel is 50‐48 mm»
- `tube_material_thickness` = 0,9 мм — «0.9 mm thickness»
- `cable_diameter_lower_rigging` = 2,5 мм — «Lower side cables and top rigging are 2.5 mm»
- `vg_mechanical_advantage` = 24-to-1  — «VG extended travel with a 24-to-1 advantage»
- `vg_pull_range_approx` = 914,4 мм — «ca. 3 ft pulled out on the VG»
- `battens_top` = 24  — «24 top»
- `battens_bottom` = 6  — «6 bottom»
- `batten_type_standard` = thin profile  — «thin wing profile with 24 top and 6 bottom battens»
- `batten_diameter_se_version` = 10 мм — «Extra-stiff 10mm CFRP battens (top and bottom sail)»
- `sail_material_double_surface_weight` = None  — «180 g heavy polyester fabric»
- `leading_edge_material` = carbon insert center  — «Carbon insert leading edge (center)»
- `leading_edge_alternatives` = PX 10 or ODL  — «leading edge can be PX 10 or ODL»
- `wingtips_style` = radial with winglets  — «radial wingtips with winglets»
- `winglets_material` = fibreglass  — «Improved fibreglass winglets»
- `hang_point_location` = on kingpost  — «The hang point is up on the kingpost»
- `frame_construction` = kingpost  — «classic and time tested kingpost construction»
- `basebar_type` = profiled aluminum  — «optional profiled Aluminum speedbar»
- `tail_fin_option` = optional  — «an optinal tail fin can be mounted to the keel»
- `nose_angle` = 130 ° — «130 degr.»
- `battens` = 24  — «24 / 6»

### Источники

- https://www.bautek.com/english/hanggliders/fizz/
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_00)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- Номера DHV-сертификатов: DHV 01-0462-12
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Bautek|Fizz||`).

### Открытые вопросы

- Винглеты — отдельной геометрией не делать (вне контракта), но концы крыла (WingTipL/R) ставить у законцовок.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N34. Airborne C4 (`air_c4`) — новая модель, приоритет P2

- **Модель:** Airborne C4; будущий файл `assets/models/glider_air_c4.glb`, запись `tools/blender/glider_params.json` → `wings.air_c4` (новая), конфиг `configs/wings/air_c4.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** соревновательное безмачтовое (DHV 3), 2008, историческое. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «Advanced high performance topless hang glider with 7075 main airframe and tubular carbon cross bars» (https://www.airborne.com.au/pages/hg_c4.php).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; преемственность: Preceded C4, succeeded by REV.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Advanced high performance topless design; 7075 main airframe and tubular carbon cross bars; Keel and leading edges made from 7075 aluminium; Crossbar wedge made from solid 7075 aluminium (CNC manufactured).
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.combat` из `glider_params.json` (модель `glider_combat.glb`: 16 лат на сторону, угол носа 130°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | air_c4 | id модели; `out` = `glider_air_c4` |
| `span_m` | 10 | паспорт (опорный размер 13.5) |
| `area_m2` | 13,5 | паспорт, опорный размер 13.5 |
| `nose_angle_deg` | 130 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,33 / 0,53 | форма базы (отношение хорд 0,227) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,5 м² |
| `nose_forward_m` | 1,32 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 12 | паспорт: верхних лат всего 24 ⇒ на сторону 12 |
| `double_surface / lower_cover` | true / 0,93 | паспорт: двойная поверхность 93 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Только карточка DHV.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| C4 13.5 | 13,5 | 10 | — | 35 | — | 93 | — | — | 24 |
| C4 14 | 14,3 | 10,4 | — | 36 | — | 93 | — | — | 24 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 24  — «24 / 6»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_05)
- Номера DHV-сертификатов: DHV 01-0428-08, DHV 01-0429-08
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Airborne|C4||13.5`, `Airborne|C4||14`).

### Открытые вопросы

- Угол носа — из руководства (в сводке: 128–133°, не подтверждено).
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N35. Airborne REV (`air_rev`) — новая модель, приоритет P2

- **Модель:** Airborne REV; будущий файл `assets/models/glider_air_rev.glb`, запись `tools/blender/glider_params.json` → `wings.air_rev` (новая), конфиг `configs/wings/air_rev.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** соревновательное безмачтовое (DHV 3), историческое. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «Topless hang glider design with cleaner airfoil and Camber Control System (CCS)» (http://www.airborne.com.au/pages/hg_rev.php).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; преемственность: Successor to C4.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Topless design with Camber Control System (CCS) for maintaining precise airfoil shape; Reduced weight compared to C4; Improved pitch characteristics; New airfoil uprights: 55mm × 26mm.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.combat` из `glider_params.json` (модель `glider_combat.glb`: 16 лат на сторону, угол носа 130°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | air_rev | id модели; `out` = `glider_air_rev` |
| `span_m` | 10,04 | паспорт (опорный размер 13.5) |
| `area_m2` | 13,5 | паспорт, опорный размер 13.5 |
| `nose_angle_deg` | 130 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,32 / 0,53 | форма базы (отношение хорд 0,227) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,51 м² |
| `nose_forward_m` | 1,32 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 12 | паспорт: верхних лат всего 24 ⇒ на сторону 12 |
| `double_surface / lower_cover` | true / 0,96 | паспорт: двойная поверхность 96 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Только карточка DHV.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| REV 13.5 | 13,5 | 10,04 | — | 34,4 | — | 96 | 90 | — | 24 |
| REV 14.5 | 14,45 | 10,64 | — | 36 | — | 95 | — | — | 24 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 24  — «24 / 8»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_00)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_07)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- Номера DHV-сертификатов: DHV 01-0449-10, DHV 01-0463-12
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Airborne|REV||13.5`, `Airborne|REV||14.5`).

### Открытые вопросы

- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N36. DesignProducts SHE 1 (`dp_she1`) — новая модель, приоритет P2

- **Модель:** DesignProducts SHE 1; будущий файл `assets/models/glider_dp_she1.glb`, запись `tools/blender/glider_params.json` → `wings.dp_she1` (новая), конфиг `configs/wings/dp_she1.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** соревновательное безмачтовое (DHV 3), 2023. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое — предположение координатора (прямого подтверждения в найденных источниках нет; проверить по фото производителя).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; преемственность: Related to Combat C (both have new AC sails).
- **Заметки по виду (из выборки, проверять по первоисточнику):** Designed by Markus Egimann of Design Products; Co-designed, developed and produced CF frames; Same planform and airfoil as Combat; New lighter cross-bar.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.combat` из `glider_params.json` (модель `glider_combat.glb`: 16 лат на сторону, угол носа 130°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | dp_she1 | id модели; `out` = `glider_dp_she1` |
| `span_m` | 10,35 | паспорт (опорный размер 12.7) |
| `area_m2` | 12,7 | паспорт, опорный размер 12.7 |
| `nose_angle_deg` | 130 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,12 / 0,48 | форма базы (отношение хорд 0,227) пересчитана под паспортные размах и площадь; площадь в плане при этом 12,7 м² |
| `nose_forward_m` | 1,2 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 13 | паспорт: верхних лат всего 26 ⇒ на сторону 13 |
| `double_surface / lower_cover` | true / 0,9 | паспорт: двойная поверхность 90 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Только карточка DHV 2023 (26 лат, 28,4 кг).

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| SHE 1 12.7 | 12,7 | 10,35 | — | 28,4 | — | 90 | 90 | — | 26 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 26  — «Anzahl Latten 26»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_03)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_10)
- Номера DHV-сертификатов: DHV 01-0504-23
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `DesignProducts|SHE 1||12.7`).

### Открытые вопросы

- Связь с Combat C — batch_c.
- Угол носа в паспорте не найден — значение базы.
- Тип конструкции принят по предположению — подтвердить по фото производителя.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N37. Seedwings Skyrunner XR (`seed_skyrunner_xr`) — новая модель, приоритет P2

- **Модель:** Seedwings Skyrunner XR; будущий файл `assets/models/glider_seed_skyrunner_xr.glb`, запись `tools/blender/glider_params.json` → `wings.seed_skyrunner_xr` (новая), конфиг `configs/wings/seed_skyrunner_xr.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** среднее (DHV 2-3), двойная поверхность 90 %. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** мачтовое — по цитате: «the performanced Skyrunner with king-post topping the intermediate gliders range» (https://en.wikipedia.org/wiki/Seedwings_Europe).
- **Заметки по виду (из выборки, проверять по первоисточнику):** High performance model.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.laminar` из `glider_params.json` (модель `glider_laminar.glb`: 13 лат на сторону, угол носа 127°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | seed_skyrunner_xr | id модели; `out` = `glider_seed_skyrunner_xr` |
| `span_m` | 10,2 | паспорт (размер в паспорте не указан) |
| `area_m2` | 14,2 | паспорт (размер в паспорте не указан) |
| `nose_angle_deg` | 127 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,32 / 0,61 | форма базы (отношение хорд 0,264) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,16 м² |
| `nose_forward_m` | 1,32 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 10 | паспорт: верхних лат всего 20 ⇒ на сторону 10 |
| `double_surface / lower_cover` | true / 0,9 | паспорт: двойная поверхность 90 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 1,15 | высоты в паспортах нет — как у базы (мачтовая) |
| `crossbar_u` | 0,58 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Только карточка DHV 2013.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Skyrunner XR | 14,2 | 10,2 | — | 32,8 | — | 90 | 90 | — | 20 |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `battens` = 20  — «20 / 4»

### Источники

- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_01)
- DHV Geräteportal (service.dhv.de/db1; файл разбора dhv_08)
- Номера DHV-сертификатов: DHV 01-0475-13
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Seedwings|Skyrunner XR||`).

### Открытые вопросы

- Тип — batch_c.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N38. Wills Wing Fusion (`ww_fusion`) — новая модель, приоритет P2

- **Модель:** Wills Wing Fusion; будущий файл `assets/models/glider_ww_fusion.glb`, запись `tools/blender/glider_params.json` → `wings.ww_fusion` (новая), конфиг `configs/wings/ww_fusion.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** продвинутое (USHPA IV Advanced), 2-поверхностное 88 %, историческое. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «Topless (no kingpost) with fully internal composite stability systems» (https://www.willswing.com/hang-gliders/archive/fusion/).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 1997 по 2001; преемственность: Succeeded by Talon and later T2/T2C.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Wills Wing's inaugural topless competition glider; Carbon fiber composite spar technology; Computer-optimized aerodynamics; Perfectly clean aerodynamic top surface without kingpost.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.sport` из `glider_params.json` (модель `glider_sport.glb`: 14 лат на сторону, угол носа 132°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_fusion | id модели; `out` = `glider_ww_fusion` |
| `span_m` | 10,39 | паспорт (опорный размер 150) |
| `area_m2` | 13,94 | паспорт, опорный размер 150 |
| `nose_angle_deg` | 128 | паспорт |
| `root_chord_m / tip_chord_m` | 2,29 / 0,55 | форма базы (отношение хорд 0,239) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,95 м² |
| `nose_forward_m` | 1,3 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 14 | паспорта нет — как у базы |
| `double_surface / lower_cover` | true / 0,88 | паспорт: двойная поверхность 88 %; `lower_cover` = процент/100 (допуск ±0,1 по фото производителя) |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Угол носа 128°, удлинение 7,7; точки поляры WW есть (176 fpm @ 23 mph, 530 fpm @ 44 mph).

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Fusion 150 | 13,94 | 10,39 | 7,7 | 34,5 | 68–122 | 88 | 85 | 128 | — |
| Fusion 141 | 13,1 | 10,06 | 7,7 | 33,6 | 66–100 | 88 | 85 | 128 | — |

Размеры каркаса/прочее опорного размера (из `wings_geometry.json`):

- `nose_angle` = 128 ° — «Nose Angle 128–132°»

### Источники

- https://www.willswing.com/hang-gliders/archive/fusion/
- https://www.willswing.com/hang-glider-placard-specifications/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Fusion||150`, `Wills Wing|Fusion||141`).

### Открытые вопросы

- Тип конструкции — batch_a.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N39. Wills Wing Talon (`ww_talon`) — новая модель, приоритет P2

- **Модель:** Wills Wing Talon; будущий файл `assets/models/glider_ww_talon.glb`, запись `tools/blender/glider_params.json` → `wings.ww_talon` (новая), конфиг `configs/wings/ww_talon.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** продвинутое (USHPA IV Advanced), историческое. Предлагаемая группа игры: `topless` (`configs/wing_groups.json`).
- **Конструкция:** безмачтовое (топлесс) — по цитате: «Topless (kingpostless) competition gliders, second generation of topless design» (https://www.willswing.com/hang-gliders/archive/talon/).
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 2001 по 2005; преемственность: Succeeded by T2/T2C.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Second generation topless design building on Fusion; Complete redesign with 42 incremental design improvements; 7075-T6 aluminum tubing for keel and leading edges; Composite carbon fiber crossbar.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.sport` из `glider_params.json` (модель `glider_sport.glb`: 14 лат на сторону, угол носа 132°, безмачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_talon | id модели; `out` = `glider_ww_talon` |
| `span_m` | 10,34 | оценка: паспорта нет; удлинение базы (7,67) × паспортная площадь (опорный размер 150) |
| `area_m2` | 13,94 | паспорт, опорный размер 150 |
| `nose_angle_deg` | 132 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,30 / 0,55 | форма базы (отношение хорд 0,239) пересчитана под паспортные размах и площадь; площадь в плане при этом 13,93 м² |
| `nose_forward_m` | 1,31 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 14 | паспорта нет — как у базы |
| `double_surface / lower_cover` | true / 0,7 | паспорта нет — как у базы |
| `kingpost_m` | 0 | безмачтовое |
| `crossbar_u` | 0,6 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4592`, `k_t = 0,5291` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Паспорт: только площадь, диапазон массы, плакат, точки поляры; размаха, угла носа, лат нет — 3D строить по базе.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Talon 150 | 13,94 | — | — | — | — | — | 85 | — | — |
| Talon 140 | 13,01 | — | — | — | — | — | 85 | — | — |
| Talon 160 | 14,86 | — | — | — | — | — | 85 | — | — |

### Источники

- https://www.willswing.com/hang-gliders/archive/talon/
- https://www.willswing.com/hang-glider-placard-specifications/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Talon||150`, `Wills Wing|Talon||140`, `Wills Wing|Talon||160`).

### Открытые вопросы

- Тип конструкции — batch_a.
- Размаха и удлинения в паспорте нет — размах оценён по удлинению базы, уточнить по первоисточнику.
- Угол носа в паспорте не найден — значение базы.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.

---

## Раздел N40. Wills Wing Cross Country (`ww_cross_country`) — новая модель, приоритет P2

- **Модель:** Wills Wing Cross Country; будущий файл `assets/models/glider_ww_cross_country.glb`, запись `tools/blender/glider_params.json` → `wings.ww_cross_country` (новая), конфиг `configs/wings/ww_cross_country.json` (новый; физику и поляру ведёт отдельная задача).
- **Класс:** продвинутое (USHPA IV Advanced), историческое. Предлагаемая группа игры: `kingpost` (`configs/wing_groups.json`).
- **Конструкция:** неизвестен — определить по фото производителя до начала работы.
- **Из открытых страниц производителя (выборка Haiku, `out/construction/`, цитаты проверены не все):** VG: yes; с 1995 по 2000; преемственность: Succeeded by Ultra Sport and Fusion.
- **Заметки по виду (из выборки, проверять по первоисточнику):** Four internal ribs per side (outboard); Three bottom surface battens (inboard); Optional winglets for enhanced performance and stability; Seamless 7075-T6 airframe tubing.
- **Что есть сейчас:** 3D-модели и конфига нет.
- **База:** копия записи `wings.magic` из `glider_params.json` (модель `glider_magic.glb`: 11 лат на сторону, угол носа 124°, мачтовое); правится только то, что в таблице ниже.

### Что задать

| Параметр | Значение | Откуда |
|---|---|---|
| `config` | ww_cross_country | id модели; `out` = `glider_ww_cross_country` |
| `span_m` | 10,36 | паспорт (опорный размер 155) |
| `area_m2` | 14,4 | паспорт, опорный размер 155 |
| `nose_angle_deg` | 124 | паспорта нет — как у базы; если появится, ставить паспортный |
| `root_chord_m / tip_chord_m` | 2,21 / 0,69 | форма базы (отношение хорд 0,314) пересчитана под паспортные размах и площадь; площадь в плане при этом 14,39 м² |
| `nose_forward_m` | 1,26 | 0,568·хорда у корня (как у всех существующих моделей; паспорта нет) |
| `battens_per_side` | 11 | паспорта нет — как у базы |
| `double_surface / lower_cover` | true / 0,6 | паспорта нет — как у базы |
| `crossbar_u` | 0,57 | данных нет — как у базы |
| `dihedral_deg, washout_deg, camber, le_thickness, basebar_width_m, luff_lines, faired_uprights, wheels, upright_bend` | как у базы | в источниках чисел нет — не выдумывать |

Формула хорд: `root = (S/b)/(k_r + k_t·ρ)`, ρ = tip/root базы, `k_r = 0,4595`, `k_t = 0,5405` (интеграл профиля хорды `build_gliders.py`; с учётом скругления законцовки).

- Паспорт: площадь, размах, удлинение, масса; угла носа, лат нет.

### Паспортные данные по размерам

| Размер | Площадь, м² | Размах, м | Удлинение | Масса крыла, кг | Пилот (hook-in), кг | Двойная пов., % | Vne, км/ч | Угол носа, ° | Лат (верх., всего) |
|---|---|---|---|---|---|---|---|---|---|
| Cross Country 155 | 14,4 | 10,36 | 7,5 | 31,8 | 77–127 | — | 88 | — | — |
| Cross Country 132 | 12,26 | 9,37 | 7,2 | 28,1 | 54–100 | — | 88 | — | — |
| Cross Country 142 | 13,19 | 9,91 | 7,4 | 29,9 | 64–109 | — | 88 | — | — |

### Источники

- https://www.willswing.com/hang-gliders/archive/cross-country/
- https://www.willswing.com/hang-glider-placard-specifications/
- Сводная таблица и цитаты: `tools/research/data/wing_passports/wings_merged.json` (ключи `Wills Wing|Cross Country||155`, `Wills Wing|Cross Country||132`, `Wills Wing|Cross Country||142`).

### Открытые вопросы

- Тип конструкции — batch_a.
- Угол носа в паспорте не найден — значение базы.
- Тип конструкции (мачтовая/безмачтовая) не установлен — определить по фото/описанию производителя и выбрать базу соответственно.

**Как делать и проверять (одинаково для всех разделов).** Параметры формы — `tools/blender/glider_params.json` → `wings.<id>`; сборка: `blender --background --python tools/blender/build_gliders.py -- <id>` (модель пишется в `assets/models/glider_<id>.glb`, исходник — `assets/source/`); затем `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import` и `godot --headless --path . --script res://scenes/models_preview/check_models.gd` (контракт имён — `docs/models.md`: ноды `Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; оси, бюджет ≤ 14 тыс. треугольников на крыло). Размах берётся из `configs/wings/<id>.json` (если конфига ещё нет — из `span_m` записи `glider_params.json`); площадь в плане проверить скриптом `python3 tools/research/data/wing_passports/wings3d_geometry.py` (допуск ±2 % от паспортной). Названий брендов и логотипов на модели и в раскраске нет; цвета — на усмотрение исполнителя (любая палитра в духе класса). Все числа — паспортные, если иное не сказано; закрутку, кривизну профиля, форму паруса, высоту кингпоста в источниках числами не найдено — оставлять значения базы.
