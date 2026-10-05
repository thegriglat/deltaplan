---
type: "research"
status: "closed"
module: "steam-assets"
updated: "2026-10-05"
summary: "Аудит лицензий сборки Deltaplan перед платной раздачей в Steam: что реально попадает в .pck и рядом с exe, что из этого разрешает коммерческое использование, какие строки ASSETS.md и тексты нужно исправить. Нарушителей (NC) в сборке нет; главные вопросы — VC++ runtime и непокрытые файлы."
related: ["docs/plan/steam-assets.md", "docs/contracts/steam-assets.md", "ASSETS.md", "tools/release/build_inventory.py", "tools/research/steam_license/README.md"]
conclusion: "В сборке нет материалов с NC/«личным использованием» (проверено по первоисточникам). 100 файлов сборки без строки ASSETS.md (в основном 87 файлов крыльев, model.onnx, ONNX Runtime, VC++ runtime, движок), 13 файлов рельефа с лицензией «как у высот / то же / открытые данные». Решения пользователя нужны по VC++ runtime (источник DLL) и по названиям реальных крыльев."
data: "tools/research/steam_license/"
applied_in: ""
---
# Аудит лицензий сборки (SA-1)

Дата 05.10.2026, копия `steam-assets/SA-1` от `feature/steam-assets` (Godot 4.7.2). Правило модуля (решение пользователя 05.10): всё в сборке, и в itch, и в Steam, разрешает коммерческое использование. Цель аудита - не доверять `ASSETS.md`, а сверить его с тем, что реально лежит в сборке.

## 1. Что такое «сборка»: как проверено

- **Эмуляция.** `tools/release/build_inventory.py` обходит проект, применяет `export_presets.cfg` (`export_filter=all_resources`, `include_filter`, `exclude_filter`), каталоги с `.gdignore` и импорт ресурсов, и пишет `build/inventory/<preset>.json` по контракту SA-К1.
- **Сверка с настоящим экспортом.** `godot --headless --export-pack` для Linux и Windows и экспорт macOS (`.pck` из `Deltaplan.app`), список файлов - собственным разбором формата PCK (`tools/research/steam_license/pck_list.py`, формат версии 4 Godot 4.7). Каждый `.pck` содержит около 1450 файлов = 803 исходных файла проекта + 42 служебных файла Godot (`project.binary`, `.godot/exported/*` с запечёнными шейдерами и т. п.). **Эмуляция совпала с настоящим экспортом до файла** на Linux и Windows (`compare_Linux.json`, `compare_Windows.json`: 803 исходных файла, расхождений 0); у macOS (экспорт сделан раньше) единственное расхождение - два временных `build/pck_*.json` самого аудита, попавшие в `.pck`, что подтверждает правило про `.json` (`compare_macOS.json`). Первая версия эмуляции расходилась в 5 файлах; причины - два неочевидных правила Godot:
  - файлы `.json` и `.ico` Godot считает ресурсами и кладёт в `.pck` **без** `include_filter` - то есть любой `.json` вне `tests/ tools/ docs/ site/` попадает в сборку (в том числе мусор, см. п. 7);
  - переводы `.translation` создаёт импорт `ui.csv`.
- **Рядом с exe** (настоящий `--export-debug`, `tools/research/steam_license/run_export.sh`): Linux - `libair_onnx.so`, `libonnxruntime.so.1`, `libdd3d.linux.editor.x86_64.so`, `deltaplan.sh`; Windows - `air_onnx.dll`, `onnxruntime.dll`, 4 DLL VC++ runtime, `libdd3d.windows.editor.x86_64.dll`; macOS - только `libdd3d.macos.editor…framework` в `.app` (расширения `air_onnx` на macOS нет). `configs/` копирует `tools/build.sh` (Linux, Windows). При экспорте `--export-release` вместо `libdd3d…editor…` кладётся `…template_release….enabled…` (скрипт: `--mode release`); лицензия та же (MIT).
- **Движок** - шаблон экспорта Godot 4.7.2 (Linux 73,7 МБ, Windows 103 МБ, macOS - внутри zip).

Итого по инвентарю (`build_inventory.py --preset all`, debug-режим):

| Пресет | Файлов | МБ | покрыто строкой ASSETS.md или `own`, коммерч. ок | нет строки ASSETS.md | строка есть, `commercial_ok` не true |
|---|---|---|---|---|---|
| Linux | 897 | 262,9 | 789 | 95 | 13 |
| Windows | 901 | 279,9 | 788 | 100 | 13 |
| macOS | 811 | 279,5 | 702 | 96 | 13 |

## 2. Таблица групп (Linux; Windows и macOS отличаются набором файлов рядом с exe)

`own` - собственный код и данные проекта (MIT, `LICENSE`). `commercial_ok`: да - лицензия разрешает; ? - в строке ASSETS.md лицензия не называет условий; нет строки - файла нет в `ASSETS.md`.

| Группа | Файлов | Лицензия (по ASSETS.md / по первоисточнику) | Коммерч. | Атрибуция | Строка в ASSETS.md |
|---|---|---|---|---|---|
| скрипты, сцены, шейдеры (`scripts/ scenes/ assets/shaders` код, `assets/easter_eggs`) | 293 | собственный, MIT | да | нет | own |
| настройки `configs/` (в .pck и рядом с exe), `locale/` | 85+85, 1 | собственный | да | нет | own |
| шрифты DSEG7, Noto Sans, Noto Sans Mono | 3 + 2 текста лицензий | OFL 1.1 (тексты лицензий лежат рядом, в сборке) | да | да | есть |
| звуки CC0 (Freesound, Kenney) | 45 | CC0 - все 16 страниц Freesound проверены (п. 3) | да | нет | есть |
| звуки CC-BY 4.0 (`land_soft_grass`, `frame_hit_alu`) | 2 | CC BY 4.0, авторы J.Zazvurek и spoonbender | да | **обязательна** | есть, в титрах |
| звуки сгенерированы процедурно (`synth_wind.py`, вариометр) | 4 | наш код, сторонних материалов нет | да | нет | есть («—») |
| модели и текстуры, собственные (Blender-скрипты): ветроуказатель, деревья, камни, кусты, палатки, прибор, птица, `cloud_*`, облака | 116 | «сгенерировано» | да | нет | есть |
| пилот `pilot.glb` | 1 | тело: MakeHuman/MPFB 2.0.17, ассеты CC0 1.0 (проверено); код MPFB (GPL) в игру не входит | да | нет (CC0) | есть |
| **крылья `glider_*.glb`, `glider_*_sail.png`** | 87 | сгенерировано `build_gliders.py` | да (наш код) | нет | **нет** (в ASSETS.md перечислены 9 старых имён, в сборке 48 моделей крыльев) |
| карты нормалей и просвечивания паруса `assets/shaders/sail/*.png` | 96 | сгенерировано | да | нет | есть |
| UI: `menu_background.jpg`, `boot_splash.png`, `logo.png`, `icon.*` | 5 | собственные кадры игры и лого автора | да | нет | есть |
| **UI: экраны загрузки `assets/ui/loading/*.jpg`** | 5 | кадры из самой игры (коммит 00923fc2) | да | отражены строки рельефа | **нет** |
| рельеф: высоты Copernicus GLO-30 (`detail.f32.br`) | 4 | лицензия Copernicus DEM | да | **обязательна** | есть |
| рельеф: фон Terrarium (`far.f32.br`), маски воды | 8 + 8 | «открытые данные», «как у высот», «то же» (текст неполный, п. 5) | ? | да (список Mapzen) | есть, но лицензия не названа |
| карта поверхности ESA WorldCover (`*_surface.png`, `*_detail10.png`) | 16 | CC BY 4.0 | да | **обязательна** | есть |
| OSM-данные `data/osm/*.json`, `data/places/hg_takeoffs.json` | 5 | ODbL 1.0 | да | **обязательна** | есть |
| текстуры ambientCG (`data/terrain/textures`) | 5 | CC0 (проверено) | да | нет | есть |
| **нейросеть `data/air_nn/model.onnx` (13 МБ)** | 1 | собственная, обучена на открытых данных (п. 4) | да | см. п. 4 | **нет** |
| аддоны `debug_draw_3d` (+ библиотеки рядом с exe), `debug_menu` | 2 + 1 + 3 | MIT | да | да | есть |
| **расширение `air_onnx` (наше)** | 2 | собственное, MIT | да | нет | own, строки нет |
| **ONNX Runtime 1.30.0** (`libonnxruntime.so.1`, `onnxruntime.dll`) | 1 / 1 | MIT + `ThirdPartyNotices.txt` (338 КБ) | да | **обязательна** | **нет** |
| **VC++ runtime, 4 DLL** (Windows) | 4 | Microsoft Software License Terms (п. 4) | **условно** | - | **нет** |
| **движок Godot 4.7.2** | 1 | MIT + сторонние компоненты (`COPYRIGHT.txt`) | да | **обязательна** | **нет** |
| мусор: `build/*.json` из рабочей копии | 5 | - | - | - | нет, п. 7 |

## 3. Первоисточники (проверено 05.10.2026)

| Что | Вывод | URL |
|---|---|---|
| Freesound, 18 звуков | CC0 - 16 страниц (611197, 20108, 836086, 154794, 57280, 556042, 556002, 609482, 504626, 862995, 399926, 454841, 855955, 437147, 454092, 146436); CC BY 4.0 - 73583 (J.Zazvurek), 352775 (spoonbender). Авторы и лицензии совпали с `assets/sounds/LICENSES.md` | https://freesound.org/s/73583/ , https://freesound.org/s/352775/ и др. |
| Kenney Impact Sounds | CC0, коммерческое использование без ограничений | https://kenney.nl/assets/impact-sounds |
| ambientCG | CC0 1.0, «даже в коммерческих целях» | https://docs.ambientcg.com/license/ |
| MakeHuman / MPFB2 (ассеты) | CC0 1.0, «в том числе коммерческие»; оговорка: права третьих лиц на товарные знаки не снимаются | https://github.com/makehumancommunity/mpfb2/blob/master/LICENSE.ASSETS.md |
| Copernicus DEM GLO-30 | бесплатная лицензия, коммерческое использование разрешено; при раздаче публике нужна строка «produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; **all rights reserved**» (в `ASSETS.md` последних слов нет) | https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM ; https://registry.opendata.aws/copernicus-dem/ |
| AWS Terrain Tiles / Mapzen | список источников: 3DEP, SRTM, GMTED2010, ETOPO1 - public domain; ArcticDEM - без ограничений; EU-DEM; LINZ CC BY 3.0 NZ; Austria CC BY 3.0 AT; Kartverket CC BY 4.0; Geoscience Australia CC BY 4.0; UK OGL v3; Canada OGL; INEGI - все разрешают коммерческое использование с атрибуцией; **NC в списке нет** | https://github.com/tilezen/joerd/blob/master/docs/attribution.md |
| ESA WorldCover 2021 v200 | CC BY 4.0; строка «© ESA WorldCover project 2021 / Contains modified Copernicus Sentinel data (2021) processed by ESA WorldCover consortium» (совпадает с `ASSETS.md`) | https://esa-worldcover.org/en/data-access |
| OpenStreetMap, плитки `tile.openstreetmap.org` | коммерческие приложения разрешены, но «доступ может быть закрыт в любой момент, платных клиентов это не защищает»; обязательны User-Agent приложения, видимая на карте атрибуция «© OpenStreetMap contributors», кеш ≥ 7 суток, массовая предзагрузка запрещена; SLA нет | https://operations.osmfoundation.org/policies/tiles/ |
| OpenTopoMap | CC-BY-SA, коммерческое использование разрешено при атрибуции «Kartendaten: © OpenStreetMap-Mitwirkende, SRTM / Kartendarstellung: © OpenTopoMap (CC-BY-SA)»; без гарантий доступности. Плитки качаются в игре, в сборку не входят | https://opentopomap.org/about |
| ONNX Runtime | MIT; в пакетах 1.30.0 есть `LICENSE`, `Privacy.md`, `ThirdPartyNotices.txt`; в `ThirdPartyNotices` встречаются только допускающие коммерческое использование лицензии (Mbed TLS - по выбору Apache 2.0) | https://github.com/microsoft/onnxruntime/blob/main/LICENSE ; файл `~/.cache/deltaplan-air-onnx-deps/onnxruntime-*/ThirdPartyNotices.txt` |
| Godot | MIT; «единственное требование - текст лицензии где-нибудь в игре»; для сторонних компонентов рекомендуют `COPYRIGHT.txt` (или ссылку на godotengine.org/license) | https://docs.godotengine.org/en/stable/about/complying_with_licenses.html |
| VC++ runtime | см. п. 4 | https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files |

Не проверялось по вебу (проверены только локальные тексты лицензий в репозитории): OFL у DSEG и Noto (`assets/fonts/*-LICENSE.txt`, `*-OFL.txt`), MIT у `debug_draw_3d` и `debug_menu` (`addons/*/LICENSE*`), godot-cpp (MIT, `LICENSE.md` в кеше зависимостей).

## 4. Ответы на вопросы задачи

### 4.1. `data/air_nn/model.onnx`: чьи данные, есть ли ограничения

Файл - сеть P2 (U-Net + FiLM, 3,22 М параметров, 9 карт 96×96 по 400 м + 18 чисел на входе), обучена на 300 рельефах и дополнительных случаях (коммит `aa136a21`, прогон `2026-10-03_p2b`, `docs/plan/air_nn.md`, `docs/archive/plan/air-nn-p3.md`). Цели обучения - поля ветра **нашего собственного** решателя (`tools/research/air3d/`, MIT). Входные карты:

- 300 вырезок 38,4 км по горам суши - тайлы Terrarium (**AWS Terrain Tiles**, тот же путь, что у игры в рантайме; источники по списку Mapzen - public domain и открытые лицензии с атрибуцией, NC нет);
- встроенные места (Алтай и др.: Copernicus GLO-30, маски воды из высот), синтетические и процедурные рельефы (наши).

Ни OSM, ни чужих моделей, ни чужих обучающих сетей, ни NC-данных в обучении нет. Веса - наш результат; ограничений на их использование нет. Чтобы не спорить о «производной работе», атрибуция Terrarium и Copernicus уже стоит в титрах (строки рельефа). **Правка:** добавить в `ASSETS.md` строку для `data/air_nn/model.onnx` (лицензия «собственный», MIT; «обучена на рельефе AWS Terrain Tiles и Copernicus DEM, цели - собственный решатель; атрибуция - строки рельефа»), SA-3.

Ограничение проверки: каталог данных обучения (`~/air_nn_data`) на этой машине отсутствует, манифест прогона не читался; вывод - по плану, README пилота и коммитам.

### 4.2. VC++ runtime (4 DLL рядом с `deltaplan.exe`)

Файлы получены из PyPI-колеса `msvc-runtime` 14.44.35112 (публикует Christoph Gohlke, лицензия «Proprietary»; внутри - текст «Distributable Code for Visual Studio 2022»), см. `native/air_onnx/README.md`. Условия Microsoft:

- Microsoft: «Distribution of the Visual C++ Runtime Redistributable package, merge modules, and individual binaries is limited to licensed Visual Studio users and is subject to Microsoft Software License Terms» (Learn, «Redistribute Visual C++ Files»).
- Список REDIST Visual Studio 2022 (Community, Professional, Enterprise): «If you have a validly licensed copy of such software, you may copy and distribute with your program the unmodified form of the files listed below» - в том числе всё в `VC\Redist` (`msvcp140.dll`, `vcruntime140.dll` и др.), без изменений. Коммерческая раздача программы не запрещена; условие - **действующая лицензия Visual Studio у распространителя**.
- Права на DLL зависят от того, у кого лицензия, а не от того, откуда файл: у колеса PyPI собственной лицензии на DLL нет. Если у автора нет установленной/принятой лицензии Visual Studio (Community бесплатна для индивидуальных разработчиков и малых организаций), опереться не на что.

**Вывод:** разрешено при действующей лицензии Visual Studio (бесплатная Community подходит для автора как индивидуального разработчика; условия лицензии нужно прочитать самому автору). Рекомендация: взять те же файлы из своей установки Visual Studio / Build Tools (`VC\Redist\MSVC\14.44.35112\x64\Microsoft.VC143.CRT`), а не из колеса; в `THIRD_PARTY_NOTICES` указать «Microsoft Visual C++ Runtime, Microsoft Software License Terms». Запасной путь - не класть DLL, а ставить `vc_redist.x64.exe` через механизм «Redistributables» Steamworks (в рамках аудита не проверялось) и для itch положить `vc_redist` рядом с инструкцией. Решение (источник DLL или установка vc_redist) - за пользователем; правка скрипта сборки - отдельная задача.

### 4.3. ONNX Runtime

MIT. Обязательные уведомления: текст MIT (`LICENSE`) и `ThirdPartyNotices.txt` (338 КБ, лежит в пакетах скачивания, в сборку сейчас не попадает). Нужно: `licenses/onnxruntime-LICENSE.txt` и `licenses/onnxruntime-ThirdPartyNotices.txt` (SA-К2), строка в `ASSETS.md` в разделе «Движок и библиотеки» (SA-3, SA-4).

### 4.4. Сгенерированные звуки

В сборке только **процедурные** звуки (`tools/sounds/synth_wind.py` - шум обтекания, бафтинг, свист тросов, синтетическое трепетание; `scripts/audio/vario_synth.gd` - вариометр): код наш, лицензия «—». Скрипты генерации моделями (`tools/sounds/gen/`: Stable Audio Open 1.0, AudioGen, AudioLDM 2, коммит `7b90dd97`, «на будущее, работа остановлена») не входят в сборку (каталог с `.gdignore`, `tools/` исключён), и ни один выходной файл в `assets/sounds` от них не происходит - все остальные звуки взяты с Freesound/Kenney (`assets/sounds/LICENSES.md`). Лицензии моделей: AudioLDM 2 - CC-BY-NC-SA, веса AudioGen - CC-BY-NC (для Steam не годятся), Stable Audio Open - Stability AI Community License (`docs/research/sounds.md`, `gen_diffusers.py`); их выходы в сборку не попали, вопрос снят. Пометок NC в истории `ASSETS.md` не было никогда (проверено `git log -S`): были только правила про них. Модели сгенерированных 3D-моделей нет: всё из Blender-скриптов (`tools/blender/`), тело пилота - MakeHuman.

## 5. Решения по каждому файлу с `commercial_ok != true` (13 файлов, все три пресета)

| Файлы | Что в ASSETS.md | Решение |
|---|---|---|
| `data/terrain/altai/far.f32.br` | «открытые данные; атрибуция источников по списку Mapzen» - не названа лицензия | AWS Terrain Tiles - источники public domain и открытые лицензии с атрибуцией, коммерческое использование разрешено (п. 3). Правка текста: «Public domain / CC BY / OGL (по источникам, список Mapzen), атрибуция по списку» - SA-3 |
| `data/terrain/{altai,…}/*_water.png` (маски рек, 6 шт.) | «как у высот», «то же» | Производные от высот: лицензия та же. Разворачивать «как у высот» в явную формулу - SA-3 (скрипт не может раскрыть ссылку на другую строку) |
| `data/terrain/{askarovo,aushkul}/detail.f32.br`, `far.f32.br`, `*_surface.png`, `*_detail10.png` (10 шт.) | «то же» | Разрешено (Copernicus, Terrarium, WorldCover); явные лицензии - SA-3 |

Ни один файл не имеет лицензии, запрещающей коммерческое использование. `commercial_ok != true` вызван только формой записи (ссылки «как у…», «то же», «открытые данные»). Формулировку для SA-К3 стоит усилить: в колонке «Лицензия» у строки входящего в сборку раздела названия лицензии не должно быть ссылок на другие строки.

## 6. Тексты «некоммерческий» (список; сайт не правим, `tools/research/steam_license/nc_texts.txt`)

В игре и конфигах:
- `locale/ui.csv:54` `about_intro` - «Некоммерческий проект» / «A non-commercial project» (экран «Об игре») - SA-3.
- `configs/world.json:952` `map_picker.user_agent` - «non-commercial open source». Это User-Agent запросов к плиткам OSM; политика OSM требует честный, опознаваемый User-Agent; слово «non-commercial» после выхода в Steam станет неверным, заменить на «open source» - SA-3 (файл `configs/` для SA-1 запрещён).

В документах и на сайте:
- `README.md:4,7` («Некоммерческий проект», «non-commercial»), `README.md:97` («помеченные ⚠ NC нельзя использовать в коммерческих целях»);
- `ASSETS.md:5,7,8` (правила вверху: «проект пока некоммерческий», «⚠ NC», «перед продажей прогон») - SA-3;
- `CLAUDE.md:3` («некоммерческий open source»), `docs/plan/…` и память проекта;
- сайт (не правим): `site/content/_index.ru.md:7,53`, `_index.en.md:7,53` («Open source and non-commercial»), `site/hugo.toml:23,30` (описание сайта); `site/content/mechanics/terrain.{ru,en}.md` (строки 52, 162–163, 171–174: «некоммерческий, но свободно раздаваемый проект», «только для умеренного, некоммерческого трафика»), `instruments.{ru,en}.md:154` (про лицензию CC-BY-NC-SA стороннего источника, не используется).
- Вне репозитория: описание на itch.io («Free, non-commercial») - проверить вручную.

## 7. Прочие находки

1. **Мусор попадает в `.pck`.** Из-за правила про `.json` (п. 1) в сборку попадают любые `.json` вне исключённых каталогов: в аудите - `build/*.json`; в основной копии (`/home/greg/deltaplan`) - неотслеживаемый `points.png` в корне проекта (рядом `points.png.import`, значит он импортирован и пакуется; 142 КБ; проверено `build_inventory.py --root`). Предложение для `export_presets.cfg` (не наш скоуп): добавить в `exclude_filter` `build/*` и держать корень чистым. - SA-4 / координатор steam.
2. **Названия реальных крыльев.** В сборке `configs/wings/*.json` (48) и модели `glider_*.glb` (48 шт.) названы по реальным изделиям (Aeros Combat C, Air и др.), в `_doc` ссылки на паспорта производителей и DHV. Модели сгенерированы нами, без логотипов; числа - факты (не охраняются авторским правом). Это не лицензионный вопрос ассета, но названия - товарные знаки третьих лиц: для платной раздачи стоит абзац «торговые марки принадлежат их владельцам» в «Об игре» (абзац о торговых марках в «Об игре» уже добавлен коммитом `d6bf039f` - проверить, что он охватывает названия крыльев). Решение - за пользователем; в эту задачу не входит.
3. **OSM-плитки в платной игре.** Политика `tile.openstreetmap.org` разрешает коммерческое использование, но без гарантий и с правом отзыва (п. 3). Инвариант пользователя (названия населённых пунктов на карте, `start_zoom ≥ 11`) от этих плиток зависит. Риск принят: нужен резервный провайдер в `configs/world.json → map_picker.basemaps` (OpenTopoMap - то же свойство; платные тарифы MapTiler/Stadia требуют ключа - см. `docs/research/terrain_sources.md`). Атрибуция должна быть **видна на карте** (по политике OSM) - проверить экран выбора старта. Новая задача (модуль start-map) или SA-3 (решение).
4. **ODbL для данных OSM.** `data/osm/*.json` и `hg_takeoffs.json` - производные базы данных OSM. ODbL требует атрибуцию и раздачу производной БД под ODbL; пока репозиторий открыт, а файлы лежат в нём в том же виде, условие выполняется. Код игры ODbL не заражает (данные читаются отдельными файлами). Записать в `ASSETS.md`/титрах одну фразу «база доступна под ODbL в репозитории» - SA-4.
5. **Строка атрибуции Copernicus** в `ASSETS.md` без «all rights reserved» - привести к официальному тексту (п. 3) - SA-3/SA-4.
6. **Библиотека dd3d.** В debug-сборке рядом с exe лежит `libdd3d…editor…` (2,7 МБ Linux, 1,7 МБ Windows; в `.gdextension` - `forced_dd3d` в `custom_features`); лицензия MIT, текст лицензии нужен в `licenses/`. Строка `addons/debug_draw_3d/` в ASSETS.md есть.
7. **Крылья в ASSETS.md.** Строка перечисляет 9 прежних имён (`glider_training…`), в сборке 48 моделей крыльев (`glider_aeros_*`, `glider_air_*` …). Нужен шаблон `assets/models/glider_*.glb` и `glider_*_sail.png` - SA-3.
8. **Экраны загрузки** `assets/ui/loading/*.jpg` - строка «собственные кадры игры (содержат рельеф и данные из строк выше)» - SA-3.
9. **История ASSETS.md.** Строк NC не было (коммит `0a1c3f52` только вписал правило «NC допустимы с пометкой», `499a1665` - реестр). Удалять нечего; правило надо убрать целиком (SA-3).
10. **macOS.** В `.pck` для macOS лежат `model.onnx` (13 МБ) и `air_onnx.gdextension`, но библиотек расширения нет (README native/air_onnx): лишние 13 МБ, не лицензионный вопрос.

## 8. Список правок

| # | Что | Почему | Задача |
|---|---|---|---|
| 1 | В `ASSETS.md` убрать правило «проект некоммерческий, NC допустимы, ⚠ NC»; записать правило «всё в сборке разрешает коммерческое использование» | устарело, противоречит решению 05.10 | SA-3 |
| 2 | Раздел «Движок и библиотеки»: Godot 4.7.2 (MIT, `COPYRIGHT.txt`), ONNX Runtime 1.30.0 (MIT, ThirdPartyNotices), VC++ runtime (Microsoft, Windows), `air_onnx` (MIT), godot-cpp (MIT, сборка), `debug_draw_3d` (MIT); для файлов рядом с exe шаблон `<exe>/…` и `engine` (в SA-К3 их формат не описан - уточнить) | 5 файлов рядом с exe и движок без строки | SA-3 (формат - координатор) |
| 3 | Строка `data/air_nn/model.onnx` (п. 4.1) | файл без строки | SA-3 |
| 4 | Строки крыльев `glider_*.glb` + `glider_*_sail.png`, экранов загрузки; перечень «сгенерировано» | 92 файла без строки | SA-3 |
| 5 | Явные лицензии вместо «как у высот», «то же», «открытые данные» (13 файлов) | `commercial_ok = null` | SA-3 |
| 6 | Тексты в игре: `locale/ui.csv about_intro`, `configs/world.json user_agent`; README, CLAUDE.md, шапка ASSETS.md | слово «некоммерческий» | SA-3 |
| 7 | `licenses/`: MIT-godot, godot-COPYRIGHT, onnxruntime LICENSE + ThirdPartyNotices, MIT-debug_draw_3d, MIT-debug_menu, OFL-1.1, CC-BY-4.0, CC0, ODbL-1.0, copernicus-dem (официальный текст с «all rights reserved»), строка Microsoft VC++ | атрибуция обязательна для MIT, CC-BY, ODbL, OFL, Copernicus, WorldCover | SA-4 |
| 8 | Решение по VC++ runtime (п. 4.2): взять DLL из своей установки VS либо ставить vc_redist; отметить в `tools/build.sh`/README `native/air_onnx` | права на DLL зависят от лицензии VS у распространителя | пользователь, затем новая задача (steam/ST-3 или air-onnx) |
| 9 | `exclude_filter`: `build/*` (мусор попадает в .pck); удалить `points.png` из корня | п. 7.1 | SA-4 / координатор steam (`export_presets.cfg`) |
| 10 | Резервный провайдер подложки карты; проверить видимую атрибуцию OSM | политика OSM, п. 7.3 | новая задача (start-map) |
| 11 | Правила SA-К3: в колонке «Лицензия» запретить ссылки «как у…/то же»; описать шаблоны `<exe>/…` и `engine` | `commercial_ok` не вычисляется | координатор (контракт v2) |
| 12 | Абзац о торговых марках охватывает названия крыльев | п. 7.2 | пользователь |
| 13 | Фраза «производная БД OSM доступна под ODbL в репозитории» в титрах | ODbL, п. 7.4 | SA-4 |
| 14 | Исправить `build_inventory.py --check` после SA-3: ожидаем `INVENTORY OK` | инвариант SA-К1 | SA-3 |

## 9. Воспроизведение

См. `tools/research/steam_license/README.md`: `run_pack.sh` (настоящий `--export-pack`), `run_export.sh` (экспорт всех пресетов), `pck_list.py`, `compare_pck.py`, `summarize.py`, `find_nc_texts.sh`, `python3 tools/release/build_inventory.py --preset all --out build/inventory [--check] [--mode release]`.
