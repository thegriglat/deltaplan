# Звуки: источники и лицензии

Все файлы можно использовать и распространять в составе игры. Лицензии: **CC0** (атрибуция не требуется,
но мы её всё равно указываем), **CC-BY 4.0** (атрибуция ОБЯЗАТЕЛЬНА — показывать в титрах/«Об игре»),
или сгенерировано нами. CC-BY-NC и «только для личного использования» не используются.

Как получены файлы freesound.org: HQ-превью (Ogg Vorbis ~140–190 кбит/с, 44,1/48 кГц), которые отдаются без логина
(`tools/sounds/fetch_candidates.py`). Лицензия превью та же, что у звука. Затем `tools/sounds/process_assets.py`:
вырезка фрагмента, фильтр верхних частот, для лупов бесшовная склейка (кроссфейд с равной мощностью),
нормализация (лупы по LUFS, one-shot по пику), fade in/out, перекодирование в Ogg Vorbis (лупы q6, остальное q4).
Время фрагмента указано в секундах исходника.

## Атрибуция для титров (CC-BY 4.0 — обязательно)

- «Body fall in grass CLOSE» — J.Zazvurek, https://freesound.org/s/73583/ — CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Изменения: вырезано 1,55–3,30 с, ФВЧ 40 Гц, нормализация, fade.
- «Aluminium Pole 2» — spoonbender, https://freesound.org/s/352775/ — CC BY 4.0. Изменения: вырезано 0–3 с, ФВЧ 60 Гц, нормализация, fade.

## Все файлы

### airflow/ — поток воздуха
| Файл | Автор | Источник | Лицензия | Изменения |
|---|---|---|---|---|
| wind_rush_loop.ogg | сгенерировано (проект deltaplan) | `tools/sounds/synth_wind.py` | — (наш) | шум обтекания, периодический IFFT-шум |
| wind_rumble_loop.ogg | сгенерировано | `tools/sounds/synth_wind.py` | — (наш) | НЧ-бафтинг, периодический |
| wires_whistle_loop.ogg | сгенерировано | `tools/sounds/synth_wind.py` | — (наш) | эоловы тоны тросов при 40 км/ч |
| wind_ears_loop.ogg | klankbeeld | [wind in ears.wav](https://freesound.org/s/611197/) | CC0 | 2–24 с, ФВЧ 30 Гц, луп (кроссфейд 2 с), −20 LUFS |
| air_rush_fast_loop.ogg | cognito perceptu | [air over mic.wav](https://freesound.org/s/20108/) | CC0 | 1–17 с, ФВЧ 60 Гц, луп (2 с), −20 LUFS |

### sail/ — парус
| Файл | Автор | Источник | Лицензия | Изменения |
|---|---|---|---|---|
| wing_under_wind_loop.ogg | bruno.auzet | [paragliding wing](https://freesound.org/s/836086/) | CC0 | 5–27,5 с, ФВЧ 60 Гц, луп (2,5 с), −22 LUFS |
| sail_luff_loop.ogg | felix.blume | [A flag flapping in the wind, at the small village of Assem Souk…](https://freesound.org/s/154794/) | CC0 | 5–27 с, ФВЧ 80 Гц, луп (2 с), −22 LUFS |
| sail_snap_01…06.ogg | _earthbound_ | [RAH_Flapping_Fabric_3.flac](https://freesound.org/s/57280/) | CC0 | 6 отдельных хлопков (8,05 / 8,86 / 10,22 / 15,88 / 29,39 / 33,41 с), ФВЧ 60 Гц, замедлено ×0,75 (ниже и «крупнее»), общий пик −3 dBFS |
| sail_flutter_synth_loop.ogg | сгенерировано | `tools/sounds/synth_wind.py` | — (наш) | синтетическое трепетание 9 Гц |

### run/ — разбег
| Файл | Автор | Источник | Лицензия | Изменения |
|---|---|---|---|---|
| step_grass_01…08.ogg | Nox_Sound | [Footsteps_Mountain_Boots_Grass_Mono.wav](https://freesound.org/s/556042/) | CC0 | 8 шагов бега из 20,7–30,5 с, ФВЧ 60 Гц, fade, общий пик −3 dBFS |
| step_gravel_01…08.ogg | Nox_Sound | [Footsteps_Mountain_Boots_Gravel_Mono.wav](https://freesound.org/s/556002/) | CC0 | 8 шагов бега из 13,4–18,0 с, то же |
| breath_run_loop.ogg | Lashim | [Quick running breathing and panting.wav](https://freesound.org/s/609482/) | CC0 | 2,0–11,35 с (границы в паузах между вдохами), ФВЧ 80 Гц, −22 LUFS |
| breath_pant_after.ogg | Lashim | [то же](https://freesound.org/s/609482/) | CC0 | 20–30 с (одышка после), пик −6 dBFS |

### landing/ — касание земли
| Файл | Автор | Источник | Лицензия | Изменения |
|---|---|---|---|---|
| land_soft_grass.ogg | J.Zazvurek | [Body fall in grass CLOSE](https://freesound.org/s/73583/) | **CC BY 4.0** | 1,55–3,30 с, ФВЧ 40 Гц, пик −3 dBFS |
| land_hard_dirt.ogg | leonelmail | [BODY FALL - V HVY - DIRT](https://freesound.org/s/504626/) | CC0 | целиком, ФВЧ 30 Гц, пик −1 dBFS |
| frame_hit_alu.ogg | spoonbender | [Aluminium Pole 2](https://freesound.org/s/352775/) | **CC BY 4.0** | 0–3 с, ФВЧ 60 Гц, пик −3 dBFS |
| kenney_impactMetal_light_000/002.ogg | Kenney | [Impact Sounds](https://kenney.nl/assets/impact-sounds) | CC0 | пик −3 dBFS |
| kenney_impactSoft_heavy_000/002.ogg | Kenney | [Impact Sounds](https://kenney.nl/assets/impact-sounds) | CC0 | пик −3 dBFS |

### frame/ — каркас и подвеска
| Файл | Автор | Источник | Лицензия | Изменения |
|---|---|---|---|---|
| creak_01…06.ogg | Valerie-Vivegnis | [26.07.04- Creaky Playground Swing - Rope Friction 1](https://freesound.org/s/862995/) | CC0 | 6 скрипов (1,62 / 4,47 / 7,43 / 10,33 / 13,16 / 30,42 с), ФВЧ 120 Гц, общий пик −6 dBFS |
| carabiner_clip.ogg | Kinoton | [Carabiner Attach to Harness](https://freesound.org/s/399926/) | CC0 | 0–2,2 с, ФВЧ 100 Гц, пик −6 dBFS |

### ambient/ — окружение
| Файл | Автор | Источник | Лицензия | Изменения |
|---|---|---|---|---|
| launch_meadow_loop.ogg | Tonmeister88 | [Mountain Meadow Switzerland Birds Insects distant cowbells](https://freesound.org/s/454841/) | CC0 | 2–66 с, ФВЧ 40 Гц, луп (4 с), −26 LUFS |
| birds_alpine_loop.ogg | Nordliecht | [04 - Birds_stereo](https://freesound.org/s/855955/) | CC0 | 1–34 с, ФВЧ 150 Гц, луп (3 с), −28 LUFS |
| cowbells_distant_loop.ogg | neilraouf | [Swiss Alps Ambiance (48kHz/24Bit)](https://freesound.org/s/437147/) | CC0 | 2–66 с, ФВЧ 80 Гц, луп (4 с), −30 LUFS |
| wind_launch_gusts_loop.ogg | kyles | [mountain wind heavy strong gusts Swiss Alps](https://freesound.org/s/454092/) | CC0 | 20–84 с, ФВЧ 30 Гц, луп (4 с), −24 LUFS |
| grass_wind_loop.ogg | felix.blume | [Dry grass rustling in the wind, in the desert of Chile](https://freesound.org/s/146436/) | CC0 | 10–53 с, ФВЧ 60 Гц, луп (3 с), −26 LUFS |

Kenney Impact Sounds: «Created/distributed by Kenney (www.kenney.nl)», CC0 (License.txt в архиве).
