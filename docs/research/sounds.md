---
type: "research"
status: "closed"
module: "instruments"
updated: "2026-09-27"
summary: "Звук: ассеты и процедурный синтез (FR-28, FR-29) — Итог: 51 файл, 8,2 МБ в assets/sounds/ (ориентир был ≤ 30 МБ)."
related: []
conclusion: ""
data: ""
applied_in: ""
---
# Звук: ассеты и процедурный синтез (FR-28, FR-29)

Итог: 51 файл, 8,2 МБ в `assets/sounds/` (ориентир был ≤ 30 МБ). Всё CC0, кроме двух файлов под CC-BY 4.0 (нужна строка в титрах),
плюс 4 файла, которые мы сгенерировали сами. Атрибуция лежит в [assets/sounds/LICENSES.md](../../assets/sounds/LICENSES.md),
реестр — в [ASSETS.md](../../ASSETS.md). Всё можно повторить скриптами из `tools/sounds/` (см. конец документа).
Вариометр здесь не рассматривается: его звук синтезирует агент instruments.

## 1. Источники: что можно брать

| Источник | Лицензия | Годится? | Комментарий |
|---|---|---|---|
| **freesound.org** | у каждого звука своя: CC0 / CC-BY / CC-BY-NC / Sampling+ | **да**, фильтр CC0 и CC-BY | Оригиналы (wav/flac) отдают только после логина или через OAuth2 API. **HQ-превью** (`cdn.freesound.org/previews/…-hq.ogg`, Vorbis 140–190 кбит/с, 44,1/48 кГц, стерео) скачиваются без логина. Лицензия превью та же, что у звука: это та же работа, только в сжатом виде. В условиях использования сайта нет запрета на превью и автоматический доступ. Качество превью для игры достаточное: мы всё равно сжимаем в Ogg. **Основной источник.** |
| **Kenney** (kenney.nl) | CC0 | **да** | Кроме UI-звуков есть «Impact Sounds»: удары металла, мягкие удары, шаги. Шаги короткие и «игровые», для реалистичного разбега слабоваты. Удары металла пригодились как лёгкий стук каркаса. |
| **Sonniss GDC bundles** | своя royalty-free: бесплатно, можно в коммерческой игре, атрибуция не нужна; **нельзя распространять как отдельные файлы** | с оговоркой | Качество студийное. Но бандлы весят 7–30 ГБ за год, и если репозиторий игры открытый, исходные wav в нём — это распространение «сырых» файлов, а его лицензия запрещает. Можно, если класть в репо только обработанные фрагменты. Не качал из-за объёма; вынесено в вопросы. |
| **OpenGameArt** | смешанные: CC0 / CC-BY / CC-BY-SA / GPL | да, выборочно | По ветру нашлись в основном короткие «игровые» лупы. Freesound по этим категориям лучше. |
| **Pixabay** (sound effects) | Pixabay Content License: бесплатно, можно в коммерческих проектах, **нельзя распространять как отдельные файлы** | с оговоркой | Сайт за Cloudflare, `curl` получает 403: без браузера не скачать. Лицензия не CC и запрещает распространять файлы отдельно, поэтому хуже CC0. Не использовал. |
| **BBC Sound Effects** (RemArc) | только личное, образовательное и исследовательское использование | **нет** | Прямо сказано: «use them in your own personal/educational projects, or licence them». Для распространяемой игры нужна платная лицензия. |
| **ZapSplat** | Standard License: бесплатный аккаунт (только mp3, атрибуция обязательна); **нельзя передавать и распространять звуки** третьим лицам | нет | Нужен логин. Условие «не распространять вне проекта» плохо сочетается с открытым репозиторием. |
| **Stable Audio Open 1.0 / small** | Stability AI Community License: бесплатно при доходе < 1 млн $/год, сгенерированное принадлежит автору | юридически да | Модели на HF закрыты (gated): нужны HF-логин и принятие лицензии, токена на машине нет (HTTP 401). Не качал. Для шумовых текстур (ветер, шелест) генерация проигрывает процедурному синтезу, потому что звук нельзя модулировать скоростью в реальном времени. |
| **AudioLDM 2** (cvssp/audioldm2) | **CC-BY-NC-SA 4.0** | **нет** | Некоммерческая лицензия. |

Вывод: CC0 с freesound плюс собственный процедурный синтез покрывают всё, генеративные модели не понадобились.

## 2. Кандидаты по категориям

Длительность — у исходника. «Формат» — оригинал на freesound (скачивали HQ-превью Ogg).
Качество (1–5) оценено по спектрограмме, огибающей, `astats` (клиппинг: flat factor / peak count, шумовой порог) и описанию автора.
Прослушать ушами было нельзя: машина без звукового выхода для агента. Поэтому оценки «на слух» надо подтвердить (см. вопросы).
Кандидаты проверены на речь моделью faster-whisper tiny с VAD: речи не нашлось ни в одном.

### 2.1 Поток воздуха у лица, в стропах и тросах (самое важное, 20–90 км/ч)

| Название | Источник | Лицензия | Длина | Формат | Кач. | Использование |
|---|---|---|---|---|---|---|
| Paragliding (gopro audio) | [freesound 328101](https://freesound.org/s/328101/) rylandbrooks | CC0 | 13 с | aiff 48k | 2 | Настоящий полёт, но микрофон GoPro (lo-fi, узкая полоса) и всего 13 с. Только как референс тембра. |
| paragliding wing | [836086](https://freesound.org/s/836086/) bruno.auzet | CC0 | 84 с | wav 48k, Schoeps MS | 5 | Крыло параплана под ветром, запись с удочки под крылом. Шелест ткани, а не ветер у ушей: ушло в категорию «парус». |
| 20110212_paraglider.01/.02 | [114627](https://freesound.org/s/114627/), [114628](https://freesound.org/s/114628/) dobroide | CC-BY 4.0 | 34 / 52 с | wav | 1 | **Отказ:** пролёт *мотопараплана*, слышен мотор. |
| wind in ears | [611197](https://freesound.org/s/611197/) klankbeeld | CC0 | 32 с | wav 44k | 4 | Ветер в ушах, НЧ-бафтинг (центроид ~165 Гц), автор пишет «loopable». → **луп низкой скорости** |
| Wind on microphone | [170439](https://freesound.org/s/170439/) Argande102 | CC0 | 80 с | Zoom H1 | 3 | Ветер в микрофоне, сильные «удары». Запасной вариант бафтинга. |
| air over mic | [20108](https://freesound.org/s/20108/) cognito perceptu | CC0 | 20 с | wav 44k | 4 | Спуск на велосипеде, автор: «surprisingly pure… not the usual bassy static». Ровный широкополосный рёв (центроид ~1,25 кГц), без клиппинга. → **слой высокой скорости** |
| Car Strong Wind Noise | [439242](https://freesound.org/s/439242/) FunWithSound | CC0 | 120 с | mp3 | 1 | **Отказ:** клиппинг (flat factor 19, 85 пиков в 0 dBFS), окраска салона. |
| air_rush | [267899](https://freesound.org/s/267899/) ChemiCatz | CC0 | 37 с | wav | 2 | Дутьё в микрофон с эквалайзером: прерывистое, звучит искусственно. |
| **синтез** (`synth_wind.py`) | наш | — | лупы 16 с | — | 4* | Шум обтекания, бафтинг и эоловы тоны тросов с физически обоснованным масштабированием по скорости. → **основа** |

**Выбор: гибрид, основа — процедурная.** Записи ветра — это одна скорость и один микрофон.
Если растягивать их по высоте тона, на 20 и 90 км/ч получаются «те же обои».
Физика аэродинамического шума простая: частота ∝ V (число Струхаля), мощность ∝ V^5…6.
Её легко повторить тремя периодическими шумовыми лупами и `pitch_scale`/`volume_db` в Godot (алгоритм в §3).
Две записи добавляют «живость», которой нет у синтеза: `wind_ears_loop` подмешивается на малой скорости и у сваливания, `air_rush_fast_loop` — на 60–90 км/ч.

### 2.2 Шелест и хлопание паруса (малая скорость, сваливание)

| Название | Источник | Лицензия | Длина | Формат | Кач. | Использование |
|---|---|---|---|---|---|---|
| paragliding wing | [836086](https://freesound.org/s/836086/) bruno.auzet | CC0 | 84 с | wav 48k | 5 | Ткань крыла под ветром: настоящий шелест нагруженного паруса. → **луп шелеста** (5–27 с) |
| flag flapping, Assem Souk | [154794](https://freesound.org/s/154794/) felix.blume | CC0 | 60 с | wav 48k, Schoeps MS | 5 | Ровное трепетание флага ночью, без фона. → **луп трепетания задней кромки** |
| flag flapping, Mojave | [187364](https://freesound.org/s/187364/) felix.blume | CC0 | 180 с | wav 96k | 4 | Хорош, но на фоне проезжают машины. |
| Fabric Flapping | [701647](https://freesound.org/s/701647/) IENBA | CC0 | 14 с | wav 48k | 4 | Фоли «плащ в полёте». Запасной вариант. |
| Tent Fabric Blow in Heavy Wind | [569539](https://freesound.org/s/569539/) bmacphail | CC0 | 66 с | wav 48k | 3 | Тихо (RMS −43 dBFS), по спектру почти без хлопков — скорее ровный шум. |
| RAH_Flapping_Fabric_3 | [57280](https://freesound.org/s/57280/) _earthbound_ | CC0 | 38 с | flac | 4 | Хлопки рубашки. Автор: если замедлить, звучит как большой флаг или парус. → **одиночные хлопки**, ×0,75 |
| Fabric flaps | [580967](https://freesound.org/s/580967/) PelicanPolice | CC0 | 39 с | iPhone | 3 | Отдельные встряхивания. Запасной вариант хлопков. |
| flag_flap_2 | [386797](https://freesound.org/s/386797/) RichieMcMullen | CC0 | 5 с | wav | 3 | Ритмичный флаг, слишком короткий для лупа. |
| **синтез** flutter | наш | — | 8 с | — | 3* | Пачки импульсов шума с частотой трепетания. Частоту задаёт `pitch_scale` ∝ V. → `sail_flutter_synth_loop` (запасной) |

**Выбор:** `wing_under_wind_loop` (фон, растёт с нагрузкой и скоростью) + `sail_luff_loop` (трепетание при малой скорости и у сваливания) + `sail_snap_01…06` (случайные хлопки при сваливании и в болтанке).
Синтетический flutter оставлен, чтобы сравнить на слух: его частоту можно точно привязать к скорости.

### 2.3 Разбег: шаги по траве и камням, дыхание, шуршание паруса

| Название | Источник | Лицензия | Длина | Формат | Кач. | Использование |
|---|---|---|---|---|---|---|
| Footsteps_Mountain_Boots_Grass_Mono | [556042](https://freesound.org/s/556042/) Nox_Sound | CC0 | 69 с | wav 48k 24 бит, Rode NTG4+ | 5 | Набор: 19 шагов, 22 шага бега, прыжки. Шумовой порог почти ноль (гейт). Горные ботинки подходят пилоту. → **шаги по траве** |
| Footsteps_Mountain_Boots_Gravel_Mono | [556002](https://freesound.org/s/556002/) Nox_Sound | CC0 | 54 с | wav 48k 24 бит | 5 | Тот же автор и структура: звучание с травой согласовано. → **шаги по камням и щебню** |
| Panicked Running Footsteps on Grass | [635052](https://freesound.org/s/635052/) sillygrizzlies | CC0 | 79 с | wav 48k | 3 | Бег по траве и листьям: сплошной поток, трудно резать на шаги. |
| Footsteps of a runner on gravel | [456038](https://freesound.org/s/456038/) florianreichelt | CC0 | 38 с | wav 48k | 2 | **Отказ:** клиппинг (flat factor 11,9, 35 пиков). |
| Footsteps Gravel Running-Stop | [436525](https://freesound.org/s/436525/) KikeVilaplana | CC0 | 6 с | wav | 3 | Коротко: мало вариаций. |
| Running on grass with wet feet | [127955](https://freesound.org/s/127955/) nathanaelsams | CC0 | 2 с | aif | 2 | Мокрая трава и босиком — не то. |
| Kenney footstep_grass_000…004 | [Kenney Impact Sounds](https://kenney.nl/assets/impact-sounds) | CC0 | 0,3 с | ogg | 2 | Шаг ходьбы, «игровой». |
| Quick running breathing and panting | [609482](https://freesound.org/s/609482/) Lashim | CC0 | 34 с | AT2020, дом | 4 | Чисто: шумовой порог −72 dB. Быстрое дыхание при беге, потом одышка. → **дыхание** |
| heavy breathing while running | [456037](https://freesound.org/s/456037/) florianreichelt | CC0 | 48 с | wav | 3 | Записано на бегу на улице: шаги и окружение мешают. |
| Young boy, fast breathing | [260187](https://freesound.org/s/260187/) SpliceSound | CC0 | 31 с | wav | 3 | Детский голос. |
| Heavy Breathing | [235519](https://freesound.org/s/235519/) ceberation | CC-BY | 5 с | wav | 3 | Короткий. |

Шуршание паруса на разбеге — тот же `wing_under_wind_loop` / `sail_luff_loop` с громкостью от скорости разбега, плюс `carabiner_clip` при пристёгивании.
**Выбор:** 8 шагов по траве, 8 по щебню (случайный выбор без повтора подряд, pitch ±5 %, громкость ±2 дБ), `breath_run_loop`, после посадки `breath_pant_after`.

### 2.4 Касание земли (мягкая и жёсткая посадка, удар каркаса)

| Название | Источник | Лицензия | Длина | Формат | Кач. | Использование |
|---|---|---|---|---|---|---|
| Body fall in grass CLOSE | [73583](https://freesound.org/s/73583/) J.Zazvurek | **CC-BY 4.0** | 6 с | mp3 | 4 | Падение тела в траву. → **мягкая посадка** (вместе с шагами пробежки) |
| BODY FALL - V HVY - DIRT | [504626](https://freesound.org/s/504626/) leonelmail | CC0 | 1,6 с | wav | 4 | Тяжёлое падение на грунт. → **жёсткая посадка** |
| Human Impact on Ground | [364690](https://freesound.org/s/364690/) alegemaate | CC0 | 0,8 с | wav | 3 | Приземление на ветки: хруст сучьев. |
| Medium Thud 1 | [342535](https://freesound.org/s/342535/) sgrowe | CC0 | 1 с | wav | 3 | Нейтральный «тук». Запасной вариант. |
| Body falls on dirt; grunts | [675923](https://freesound.org/s/675923/) craigsmith | CC0 | 12 с | wav | 3 | С кряхтением. Можно взять для «жёсткой» посадки. |
| Aluminium Pole 2 | [352775](https://freesound.org/s/352775/) spoonbender | **CC-BY 4.0** | 15 с | wav 48k | 4 | Удар по алюминиевой трубе: каркас дельтаплана именно из таких труб. → **удар каркаса** |
| metal_pipes_collision | [848209](https://freesound.org/s/848209/) Mihacappy | CC0 | 146 с | wav | 2 | Трубы катятся и гремят, изолированных ударов мало. Отказ. |
| Kenney impactMetal_light / impactSoft_heavy | [Kenney](https://kenney.nl/assets/impact-sounds) | CC0 | 0,3–0,6 с | ogg | 3 | Лёгкий стук трубы, глухой удар. → **слои** |

**Выбор:** мягкая посадка = `land_soft_grass` + 1–2 шага. Жёсткая = `land_hard_dirt` + `frame_hit_alu` (громкость ∝ вертикальной скорости) + `kenney_impactSoft_heavy_*`.
Касание базовой трубой = `kenney_impactMetal_light_*`.

### 2.5 Окружение: ветер на старте, птицы, коровы, тишина на высоте

| Название | Источник | Лицензия | Длина | Формат | Кач. | Использование |
|---|---|---|---|---|---|---|
| Mountain Meadow Switzerland Birds Insects distant cowbells | [454841](https://freesound.org/s/454841/) Tonmeister88 | CC0 | 71 с | wav 48k 24 бит, 2×NT5 AB | 5 | Горный луг: птицы, стрекот, далёкие колокольчики. Ровно, без событий-«выбросов». → **основной фон старта** |
| 04 - Birds_stereo (alpine pasture 6 a.m.) | [855955](https://freesound.org/s/855955/) Nordliecht | CC0 | 35 с | wav 48k | 5 | Только птицы, фон очень тихий. → **слой птиц** |
| Swiss Alps Ambiance (distant cow bells) | [437147](https://freesound.org/s/437147/) neilraouf | CC0 | 67 с | wav 48k 24 бит | 4 | Далёкие колокольчики. → **«деревня/коровы»**, тихий слой |
| Mucche al pascolo | [646637](https://freesound.org/s/646637/) lascia | CC0 | 50 с | wav | 3 | Коровы и мычание вблизи: слишком близко. |
| mountain wind heavy strong gusts Swiss Alps | [454092](https://freesound.org/s/454092/) kyles | CC0 | 171 с | flac 48k | 4 | Порывистый ветер на хребте. → **ветер на старте** |
| Tramontane Wind on Top of the Canigou | [759918](https://freesound.org/s/759918/) davidlagarde | CC0 | 328 с | wav | 4 | Очень сильный ветер. Запасной вариант для штормовой погоды. |
| Dry grass rustling in the wind | [146436](https://freesound.org/s/146436/) felix.blume | CC0 | 180 с | wav 48k | 4 | Шелест травы. → **трава у старта**, громкость ∝ ветру |
| Rocky Mountain Outdoors: wind and birds | [288899](https://freesound.org/s/288899/) petebuchwald | CC0 | 90 с | wav | 2 | Очень тихая запись (RMS −67 dBFS): при нормализации полезет шум. |
| skylark | [277149](https://freesound.org/s/277149/) Andy_Gardner | CC0 | 100 с | wav 96k | 2 | Жаворонок, но на фоне ветряки и дождь. |
| Tempelhof Skylark | [399221](https://freesound.org/s/399221/) Veridiansunrise | CC0 | 50 с | wav | 3 | Тревожные крики, городской фон. |
| air tone village night | [637147](https://freesound.org/s/637147/) kyles | CC0 | 93 с | wav | 2 | Ночь, очень тихо: нашему дню не подходит. |

**Выбор:** старт = `launch_meadow_loop` + `birds_alpine_loop` + `wind_launch_gusts_loop` (∝ ветру) + `grass_wind_loop` (∝ ветру) + `cowbells_distant_loop` (тихо).
**Тишина на высоте** — это отсутствие звука: все слои окружения затухают с высотой над землёй (AGL, см. §3.4). На высоте остаются только поток воздуха, парус и вариометр.

### 2.6 Скрип каркаса и подвески

| Название | Источник | Лицензия | Длина | Формат | Кач. | Использование |
|---|---|---|---|---|---|---|
| Creaky Playground Swing - Rope Friction 1 | [862995](https://freesound.org/s/862995/) Valerie-Vivegnis | CC0 | 48 с | wav 48k | 4 | Трение натянутой верёвки: похоже на подвеску и стропу под нагрузкой. → **creak_01…06** |
| Rope Friction 2 | [862996](https://freesound.org/s/862996/) | CC0 | 182 с | wav | 4 | Запасной вариант, больше вариаций. |
| Slow Creaking Stereo (chair) | [130364](https://freesound.org/s/130364/) harveyism | CC0 | 28 с | wav 88k | 2 | Очень тихо (−57 dBFS), «деревянный» скрип. |
| Mooring Rope | [145721](https://freesound.org/s/145721/) Rmutt | CC0 | 69 с | minidisc | 2 | **Отказ:** клиппинг. |
| Carabiner Attach to Harness | [399926](https://freesound.org/s/399926/) Kinoton | CC0 | 12 с | wav 48k | 4 | Щелчок карабина о подвеску. → **пристёгивание** |
| carabiner dangle | [138961](https://freesound.org/s/138961/) Huggy13ear | CC-BY 4.0 | 12 с | wav | 3 | Звяканье карабина. Запасной вариант. |

**Выбор:** `creak_01…06` — случайно, когда быстро меняется перегрузка (|dG/dt| > порога) и в начале разбега, тихо (−18…−24 дБ относительно потока). `carabiner_clip` — при пристёгивании перед стартом.

## 3. Процедурный синтез: что и как делать в Godot

### 3.1 Поток воздуха — основной алгоритм (рекомендуется)

Готовые заготовки лежат в `assets/sounds/airflow/`. Все лупы **строго периодичны**: IFFT шума с заданным спектром, LFO с целым числом периодов на длину лупа.
Поэтому они бесшовные без кроссфейда. Реальное время — три-пять `AudioStreamPlayer` на шине `Airflow` плюс эффекты. Процессор почти не нагружается (NFR-1).

| Слой | Файл | pitch_scale | Громкость, дБ (V — воздушная скорость, V_ref = 40 км/ч) | Физика |
|---|---|---|---|---|
| Шум обтекания | `wind_rush_loop.ogg` (пик спектра ~450 Гц при V_ref) | `V / V_ref`, 0,4…2,5 | `rush_db + 10·n·log10(V/V_ref)`, n ≈ 5 | Струхаль: частоты ∝ V; дипольный шум ∝ V^5…6 |
| Бафтинг у ушей и шлема | `wind_rumble_loop.ogg` (20–250 Гц, AM ±10 дБ) | `0,7 + 0,3·V/V_ref` | `rumble_db + 60·log10(V/V_ref)` + турбулентность атмосферы | Пульсации давления у ушей; растут в болтанке |
| Эоловы тоны тросов | `wires_whistle_loop.ogg` (4 «троса» Ø 2,4 / 3 / 3,8 / 4,8 мм при V_ref) | `V / V_ref` | `wires_db + 60·log10(V/V_ref)`, мягкий порог включения ~35 км/ч | f = St·V/d, St ≈ 0,2: при 60 км/ч и Ø 3 мм ≈ 1,1 кГц |
| Записанный ветер в ушах | `wind_ears_loop.ogg` | 1 | кроссфейд: полная громкость при 20–35 км/ч, затухание к 50 км/ч | Живость на малой скорости |
| Записанный скоростной поток | `air_rush_fast_loop.ogg` | `0,85 + 0,15·V/V_ref` | появляется с 55 км/ч, полная громкость к 80 км/ч | Живость на большой скорости |

Эффекты на шине `Airflow`:
1. `AudioEffectLowPassFilter`: `cutoff_hz = lp_base_hz + lp_per_kmh·V` (800 + 60·V, ограничение 16 кГц). На малой скорости звук глухой, на большой открывается «шипение».
2. `AudioEffectPanner` или два плеера L/R: панорама по углу скольжения β: `pan = clamp(β / 20°, −1, 1) · 0,6`. Ветер дует в «наветренное» ухо.
3. Опционально `AudioEffectCompressor`, чтобы 90 км/ч не забивали вариометр. Вариометр — на отдельной шине, всегда поверх.

Модуляции (в `_process`, сглаживание τ ≈ 0,1–0,3 с, чтобы не было «ступенек»):
- V — **воздушная** скорость, не путевая (при встречном ветре на старте поток есть и без движения);
- турбулентность: `rumble_db += turb_gain_db · |a_vert − a_vert_сглаж| / g` (или интенсивность турбулентности из атмосферы);
- у сваливания (α > α_крит − 3°) бафтинг +4…6 дБ: срыв потока с крыла.

Файл `tools/sounds/preview/airflow_sweep_demo.ogg` — оффлайн-рендер этого алгоритма (20 → 90 → 20 км/ч за 24 с), чтобы подобрать коэффициенты на слух.
Код рендера — `demo_sweep()` в `tools/sounds/synth_wind.py`.

### 3.2 Полностью процедурный вариант (AudioStreamGenerator), если лупов окажется мало

Моно, 44,1 кГц, буфер 0,1 с. В `_process` заполнять `get_frames_available()` кадров:
```
white = randf_range(-1, 1)
pink  = фильтр Пола Келлета (7 полюсов) от white          # 1/f
brown = brown*0.995 + white*0.02                          # для бафтинга
# SVF (state-variable filter, Chamberlin), f_c = f_ref * V/V_ref, Q ≈ 0,7 → «шум обтекания»
# 2–4 узких SVF (Q ≈ 40–80) на f_i = 0,2·V/d_i, вход — white, амплитуда каждого — случайная медленная огибающая → «тросы»
# бафтинг: brown через LP 200 Гц, умножить на exp(k·lfo), lfo — сглаженный случайный процесс 0,5–6 Гц
out = g_rush(V)*rush + g_rumble(V)*rumble + Σ g_wire(V)*wire_i
```
Нагрузка: ~40 операций на сэмпл, в GDScript это ~1,8 млн оп/с — несколько процентов ядра.
Этот вариант лучше лупов в одном: частоты тросов и полосы меняются непрерывно, без артефактов ресэмплинга при `pitch_scale` > 2.
Если GDScript окажется медленным — перенести в C# или GDExtension.

### 3.3 Парус

- `wing_under_wind_loop`: громкость ∝ `20·log10(q·n_z)` (q — скоростной напор, n_z — перегрузка), `pitch_scale = 0,9 + 0,2·V/V_ref`.
- `sail_luff_loop` (трепетание): громкость = `luff_db · s`, где `s = smoothstep(V_trim − 5, V_stall, −V)` на малой скорости + `smoothstep(α_крит − 4°, α_крит, α)`. `pitch_scale = 0,8 + 0,4·V/V_ref`.
- `sail_snap_*`: пуассоновский процесс с частотой `λ = snap_rate_hz · s²` (до ~3 Гц у сваливания), случайный файл, pitch 0,9–1,1.
- Альтернатива — `sail_flutter_synth_loop` (импульсы 9 Гц): `pitch_scale = f_flutter / 9`, где `f_flutter ≈ flutter_k · V` (порядка 5–15 Гц).
  В GDScript можно синтезировать напрямую: огибающая `exp(−φ/0,12)` на фазе `φ` с частотой f_flutter × полосовой шум ~700 Гц, амплитуда хлопка случайна.

### 3.4 Окружение и разбег

- Все ambient-слои умножаются на `fade_agl = 1 − smoothstep(agl_fade_start_m, agl_fade_end_m, AGL)`: 20 → 150 м для птиц и травы, 50 → 400 м для колокольчиков.
- `wind_launch_gusts_loop` и `grass_wind_loop`: громкость ∝ `20·log10(W / W_ref)` (W — ветер у земли из атмосферы), только на земле и низко.
- Шаги: интервал шага = `stride_m / V_ground` (stride ≈ 1,2–1,6 м при беге). Поверхность — трава или щебень по данным рельефа/ландшафта, по умолчанию трава. Случайный файл без повтора подряд, pitch ±5 %, громкость ±2 дБ.
- Дыхание: `breath_run_loop` во время разбега, громкость растёт со временем разбега. `breath_pant_after` — один раз после посадки или остановки.

### 3.5 Предложение ключей для `configs/audio.json` (пишет агент instruments)

```
"airflow": { "v_ref_kmh": 40, "rush_db": -14, "rush_exp": 5.0, "rumble_db": -16, "rumble_exp": 6.0,
             "wires_db": -26, "wires_on_kmh": 35, "lp_base_hz": 800, "lp_per_kmh_hz": 60,
             "ears_fade_kmh": [35, 50], "fast_fade_kmh": [55, 80], "pan_beta_deg": 20, "smooth_s": 0.2,
             "stall_buffet_db": 5, "turb_gain_db": 6 },
"sail":    { "wing_db": -22, "luff_db": -16, "snap_rate_hz": 3.0, "stall_margin_deg": 4 },
"ambient": { "agl_fade_m": [20, 150], "cowbells_agl_fade_m": [50, 400], "wind_ref_ms": 5 },
"run":     { "stride_m": 1.4, "step_pitch_jitter": 0.05, "step_gain_jitter_db": 2 }
```

## 4. Проверка качества (`tools/sounds/check_assets.py`)

- **Громкость:** лупы нормированы по EBU R128. Поток и парус −20…−23 LUFS, окружение −24…−30 LUFS: фон заведомо тише. One-shot-наборы нормированы общим пиком, естественный разброс громкости внутри набора сохранён. True peak везде ≤ −1 dBFS.
- **Стыки лупов:** click = |x[0] − x[−1]| / p99(|x[n+1] − x[n]|) после декодирования Ogg. У всех лупов 0,01…0,58: стык не отличается от обычной пары соседних сэмплов. ΔRMS на стыке ≤ 3 дБ.
  Исключения по ΔRMS — птицы (6,6 дБ) и дыхание (8,7 дБ): там границы стоят между событиями (пауза между вдохами, щебет), так и задумано.
- **Найденная проблема:** при Vorbis q4 шум квантования на стыке давал скачок в ~6 раз больше типичного на НЧ-материале (`wind_ears_loop`, центроид 165 Гц). Это тихий «тик» на каждом обороте лупа.
  Поэтому все лупы кодируются в **q6**: скачок уменьшился в ~4 раза и стал ниже p99. One-shot — q4.
- **Клиппинг** проверен у всех кандидатов (`astats`: flat factor, peak count). Клипованные отброшены: 439242, 456038, 145721.
- Флаги `loop=true` в `.import` для `*_loop.ogg` ставит `tools/sounds/set_loop_flags.sh`. Можно и в коде: `stream.loop = true`.

| файл | длит., с | кан. | LUFS | LRA | TP, dBFS | центроид, Гц | стык: click / ΔRMS дБ |
|---|---|---|---|---|---|---|---|
| airflow/air_rush_fast_loop.ogg | 14.00 | 2 | -20.0 | 0.2 | -7.0 | 1253 | 0.27 / 1.4 |
| airflow/wind_ears_loop.ogg | 20.00 | 2 | -21.7 | 4.0 | -1.1 | 167 | 0.29 / 2.9 |
| airflow/wind_rumble_loop.ogg | 16.00 | 2 | -20.2 | 0.6 | -1.0 | 242 | 0.39 / 1.8 |
| airflow/wind_rush_loop.ogg | 16.00 | 2 | -20.2 | 0.2 | -9.9 | 2777 | 0.58 / 0.5 |
| airflow/wires_whistle_loop.ogg | 16.00 | 1 | -25.9 | 4.1 | -13.8 | 774 | 0.57 / 1.7 |
| ambient/birds_alpine_loop.ogg | 30.00 | 1 | -28.2 | 11.5 | -13.7 | 3714 | 0.02 / 6.6 |
| ambient/cowbells_distant_loop.ogg | 60.00 | 2 | -30.0 | 5.4 | -3.9 | 4926 | 0.18 / 4.0 |
| ambient/grass_wind_loop.ogg | 40.00 | 2 | -26.0 | 10.7 | -9.2 | 4980 | 0.41 / 2.6 |
| ambient/launch_meadow_loop.ogg | 60.00 | 2 | -26.1 | 4.2 | -11.8 | 4146 | 0.26 / 0.7 |
| ambient/wind_launch_gusts_loop.ogg | 60.00 | 2 | -24.2 | 7.4 | -5.7 | 2519 | 0.54 / 2.6 |
| run/breath_run_loop.ogg | 9.35 | 1 | -22.9 | 3.9 | -4.4 | 3160 | 0.01 / 8.7 |
| sail/sail_flutter_synth_loop.ogg | 8.00 | 1 | -22.1 | 0.7 | -4.8 | 2528 | 0.24 / 3.2 |
| sail/sail_luff_loop.ogg | 20.00 | 2 | -23.4 | 4.6 | -1.0 | 1583 | 0.20 / 1.3 |
| sail/wing_under_wind_loop.ogg | 20.00 | 2 | -22.2 | 1.6 | -10.9 | 2550 | 0.34 / 0.7 |

Размер: airflow 1,3 МБ, ambient 5,3 МБ, sail 1,1 МБ, run 0,4 МБ, landing и frame 0,3 МБ. Всего 8,2 МБ.

## 5. Как повторить

```
C=/tmp/snd_cache
python3 tools/sounds/fs_search.py "wind grass" --license cc0          # поиск кандидатов (без ключа)
python3 tools/sounds/fetch_candidates.py $C                           # HQ-превью + meta.json (лицензии со страниц)
curl -L <KENNEY_URL из process_assets.py> -o k.zip && unzip k.zip -d $C/kenney_impact
uv run --no-project --with numpy --with scipy python tools/sounds/process_assets.py $C
uv run --no-project --with numpy --with scipy python tools/sounds/synth_wind.py
uv run --no-project --with numpy --with scipy python tools/sounds/check_assets.py [--md]
godot --headless --path . --import && tools/sounds/set_loop_flags.sh && godot --headless --path . --import
```
Списки кандидатов — `tools/sounds/candidates.py`. Что и откуда вырезается — таблицы `LOOPS`, `HITS`, `SINGLES` в `process_assets.py`.
