---
type: "research"
status: "active"
module: "site-research"
area: "release"
updated: "2026-10-21"
data: "нет: аудит чтением, данных не создаёт"
applied_in: "нет: аудит, код не менялся"
summary: "SRS-1: 47 тем исследований против сайта (ru+en) и docs/guide: есть 25, частично 13, нет 7, устарело 2; графики, объём."
conclusion: "Сайт покрывает ветер, термики, полёт «Маятник», рельеф и крылья; устарели облака (SCF-1), растительность и дома по региону, en-абзац про переворот в flight; нет вывода про z_i по рельефу и опускание, ощущение скорости, платформу движения, тренировочный остров, k_relax (А2); почти нет графиков исследований на страницах."
related: ["docs/contracts/site-research.md", "docs/plan/site-research.md", "docs/registry/findings.md", "docs/registry/research.md"]
contracts: [{"id": "SRS-К1", "version": 1}]
---

# Аудит сайта: исследования против страниц и docs/guide (SRS-1)

Контракт — SRS-К1 v1 (`docs/contracts/site-research.md`). Только аудит: сайт и `docs/` не правились.

## Метод

- Источники тем: `docs/registry/findings.md`, `docs/registry/pendulum-findings.md`, `docs/registry/research.md`, `docs/research/*.md` со статусом `active`/`closed` (отклонённое и `superseded` — одна строка там, где оно описано на сайте).
- Сайт: `site/content/` — `mechanics/*`, `mechanics/air-model/*`, `approaches`, `research/_index`, `docs/goals`, `wings/*`; ru и en читались в паре (число заголовков и чисел сравнивалось по всем страницам, текст — там, где расходилось).
- «На сайте» = `есть` — вывод и его число на странице есть и совпадают с источником; `частично` — часть вывода или нет чисел; `устарело` — на странице описано то, чего в `main` уже нет; `нет` — вывода на сайте нет.
- docs/guide: «ок» — числа из руководства сверены с `configs/*.json` и кодом копии; «ок*» — наличие раздела и согласие с исследованием по тексту, с кодом не сверялось. Сверено с кодом: поле облачности (`configs/atmosphere.json → cloud_field`), нагрев по покрову (`configs/weather_model.json → heating.lag_h`, таблица классов), `k_relax`/`Pr_t` (`air_case.gd`), шаг высот WebP (`dem_stage.gd`), сетка OSM-тайлов (`osm_grid.gd`), пресеты графики (`configs/game.json`), порт и размер пакета платформы (`motion_output.gd`), число крыльев (48 = 3 + 11 + 19 + 15), `billow_shift_deg`, формула целей.
- Игру не запускали. Картинки не открывались: графики оценены по именам файлов и README.
- Графики: `tools/research/<тема>/…` в копии; `build/screenshots/<модуль>/…` — главная копия (`/home/greg/deltaplan/build/screenshots/`), только чтение.
- Объём: S — абзац или подпись к графику; M — раздел, 1–2 графика; L — новая страница или переписать страницу.
- Ограничения: числа на странице проверены по ключевым выводам реестров, а не по каждой строке исследований; полнота — 47 тем, самые «мелкие» выводы реестра (шум замеров G3, отклонённые варианты внутри раздела) не вынесены в строки.

## Таблица

| Тема | Источник | Статус в игре | Страница сайта | На сайте | Что не так | Графики | Объём | docs/guide |
|---|---|---|---|---|---|---|---|---|
| Поле облачности (CLF-1): жизнь облака, снос, таяние | docs/research/cloud_field.md#1-схема | active | site/content/mechanics/clouds | устарело | SCF-1. Страница описывает «одно облако на термик» и 8 башен; в игре с 1.5.19 поле региона 96 × 96: τ_form 240 с, τ_life 900 с, τ_evap 1200 с × clamp(мощность/1 км, ½, 2), через 5 мин без подъёма остаётся > 50 % покрытия, через 90 мин < 10 %. | build/screenshots/cloud-field/CLF-1/ongudai_strong.png, ongudai_weak.png, almaty_strong.png; build/screenshots/cloud-field/CLF-5/ongudai_high.jpg, ongudai_low.jpg | L | ок |
| Цена слоя облаков и профиль кадра (PF-10) | docs/perf/frame_profile/cloud-field.md; docs/perf/frame_profile/after-fixes.md | active | site/content/mechanics/clouds | частично | SCF-1. Есть буфер 0,33/0,5/0,75 по пресету, но нет PF-10: GPU medium 14–29 → 5,3–8,2 мс, high 33–83 → 10–12 мс; облака — 56–93 % кадра до правок; слой облаков в 6–7 раз дешевле боксов main на сильном дне Онгудая | build/screenshots/cloud-field/CLF-5/cost.json (таблица) | S | ок |
| Облачное поле по сети: снимок ведущего | docs/registry/findings.md#cloud-field | active | site/content/mechanics/multiplayer | частично | «Атмосфера по сети не передаётся» верно, исключение про `thermalSources` есть; нет второго исключения: снимок поля облачности 10–25 КБ раз в 30 с, подтяжка к нему за 10 с, чужая сетка/версия отвергается | нет | S | ок |
| z_i по рельефу (CLF-9) | docs/research/cloud_field.md#z_i-по-рельефу | active | site/content/mechanics/air-model/thermals | нет | Потолок термика описан «по инверсии»; нет вывода: z_i следует сглаженному рельефу (α ⅓, σ 5 км), потолки над хребтами +100…+400 м (Алматы сильный p50/p90 +147/+414 м), над низиной z_i дня | build/screenshots/cloud-field/CLF-9/almaty_strong_zi.png, ongudai_strong_zi.png, askarovo_strong_zi.png | M | ок |
| Опускание и честная неудача «над городом ясно» (CLF-10) | docs/research/cloud_field/subsidence.md | active | site/content/mechanics/air-model/thermals | нет | Описано фоновое опускание −0,3…−1 м/с пресета, а не опускание циркуляции: W̄ σ 10 км, τ_s 3 ч, низина Алматы −1,2 см/с, Δz_s p50 130 м, покрытие 0,25 → 0,23 (не ≤ 0,1; термики равнины доходят до LCL 3421 м) | build/screenshots/cloud-field/CLF-10/almaty_strong_sub.png, askarovo_strong_sub.png | M | ок |
| Нагрев по покрову вместо H₀ = 330 Вт/м² | docs/registry/findings.md#surface-heat; docs/research/surface_params.md | active | site/content/mechanics/air-model/thermals | есть | — (луг 209, лес 289, запаздывание по классам совпали с `weather_model.json`; en совпадает) | tools/research/air_thermals/out/fig_before_after_ongudai_d400_h12.png, fig_sources_ongudai_d400_h12.png | S | ок |
| Озёра днём не греют; вода без OSM (WorldCover) | docs/registry/findings.md#surface-heat; docs/research/lakes_worldcover.md | active | site/content/mechanics/terrain | есть | — (около −30 Вт/м² над Аушкулем против p10 −31,5; IoU 0,86–0,97 на странице не приведён, не нужен игроку) | нет | S | ок |
| Источник термика не над водой (VI-7) | tools/research/sea_thermals/README.md | active | site/content/mechanics/air-model/thermals | есть | — (числа 957 → 0 на странице нет; вывод «над водой термиков нет» есть) | нет | S | ок* |
| Точка росы, дымка и видимость | docs/registry/findings.md#weather-by-temperature | active | site/content/mechanics/visual-cues | частично | После haze-humidity. Раздел «Дымка и видимость» отсылает на terrain; влажности в игре нет, точка росы — климатология месяца | нет | S | ок* |
| Погода из прогноза (температура, ветер, облачность) | docs/registry/findings.md#weather-by-temperature | active | site/content/mechanics/weather | есть | — (LCL 122–125 м/К ✓; точка росы — после haze-humidity) | нет | S | ок* |
| Pr_t = 0,85 и отбор Морриса | docs/research/air-model-sensitivity.md | active | site/content/approaches | есть | — (1230 прогонов, ×2,05, подъём −15 % ✓; графиков нет) | tools/research/morris/out/fig_degeneracy.png, fig_mu_sigma.png, fig_heatmap_key.png | S | ок |
| Калибровка Professor: Askervein + Perdigão | docs/research/air-model-tune.md | active | site/content/mechanics/air-model/_index | есть | — (χ²/ndf 208/76, λ/h 0,25 ✓) | tools/research/tune/out/fig_s1_chi2.png, tools/research/recal/out/fig_chi2_lf_alpha.png, tools/research/cases/b1/out/fig_fit_residuals.png | S | ок* |
| Отрыв за грядой, Perdigão: границы модели | docs/registry/findings.md#air-model | active | site/content/mechanics/air-model/turbulence | есть | — (L/D 0,40 против 0,50 и 0,20 против 0,50 — в approaches; ТКЭ завышена в 2–3 раза ✓) | tools/research/cases/perdigao/out/fig_section_ne.png, fig_section_sw.png | S | ок* |
| Болтанка и ротор: калибровка AP-10 | docs/research/air_phase_results.md | active | site/content/mechanics/air-model/turbulence | есть | — (слой сдвига «несколько сотен метров», опускание единицы процентов ✓) | tools/research/air_turb/out/spectrum.png, tools/research/air_phase/out/fig_shear_layer.png | S | ок* |
| Лес в модели воздуха: DSM + доля леса, z0 по клетке | docs/registry/findings.md#air-model | active | site/content/mechanics/air-model/turbulence | частично | В границах: «над лесом болтанка занижена — поверхность везде луг», а нагрев и z0 учитывают покров (Алтай z0 0,216 м, над лесом ветер на 30 м ×0,95); в реестре d = 0,7·h_c = 12,6 м, в `world.json` `canopy_dsm_height_m` = 10 — какой смысл у какого числа, проверить (вопрос шлюзу) | нет | S | расходится: реестр 12,6 м против `canopy_dsm_height_m` 10 в конфиге, проверить в игре |
| Фазы ветра: границы, Fr ≲ 0,25, порог U/N | docs/research/air_phase.md | active | site/content/mechanics/air-model/wind-phases | частично | Таблица фаз A–H есть; нет порога несходимости (N_c = 0,0087/0,0113/0,0142 1/с при U_sat 3/4,5/6 м/с), «штиль Fr ≲ 0,25 Пикар не находит», угла линии тени 9,9° (хребет 7,3°); на странице ноль картинок | tools/research/air_phase/out/fig_phase_schematic.png, fig_cases_game.png, fig_nonconv_fr_game.png, fig_order_game.png, fig_sections.png | M | ок* |
| Несходимость в штиль и k_relax 0,5 → 0,1 (А2) | docs/registry/findings.md#air-model | active | site/content/approaches | нет | Есть причина (слабый ветер ниже 2,5 м/с), нет исправления: все 16 из 16 cbl-случаев сходятся, цепочка игры 892 итерации вместо 3712 (был предельный цикл); 6 из 24 не сходились после смены параметров | tools/research/a2pre/out/fig_a2_hist.png, fig_a2_cost.png, fig_matrix_iters.png | S | ок |
| Два прохода поля и болтанка у старта (AS-1) | docs/registry/findings.md#air-start | active | site/content/approaches | есть | — (30 из 30 в ±10 %, σw 0,04 → 0,73 → 1,05 ✓) | tools/research/air_start/out/after/fig/01_profile_over_start.png, 02_wind6_vs_trim.png, 06_ratio_over_start_6ms.png | S | ок* |
| «Сдувает» на старте: проверка физики крыльев (WPC) | docs/registry/findings.md#wing-physics-check | active | site/content/approaches | есть | — (причина — ветер меню, не поляры ✓; Vmin на 5–30 % выше сваливания поляр у 22 крыльев — одна строка) | tools/research/wing_physics_check/out/fig_penetration_6ms.png, fig_diff_pct.png, fig_takeoff.png | S | ок* |
| 2D-прототип «нагрев → плавучесть → поток» (клеточный автомат) | docs/registry/findings.md#heat-ca; tools/research/heat_ca/README.md | closed | site/content/research/_index | есть | — (пять сценариев, шесть опытов; ссылка на `out/summary.md`) | tools/research/heat_ca/out/time_50.png, conv_flow.png, mass_balance.png, fields_s1_sun_one_slope.png | S | — |
| 3D-эталон на Онгудае, кеш поля воздуха | docs/research/air_field_cache.md; tools/research/air3d/summary.md | closed | site/content/approaches | есть | — (57 564 варианта, 23,5 МБ ✓) | tools/research/air3d/out (15 png), tools/research/air_runtime/out/blend_trace.png | S | ок* |
| Нейросеть вместо решателя (P1–P3, ann2, ONNX) | docs/registry/findings.md#air-nn; docs/research/ann2_data_limit.md | closed | site/content/approaches | есть | — (отклонено; таблицы P2/P3 ✓) | tools/research/air_nn_pilot/ (21 png) | S | — |
| WindNinja как независимый эталон | docs/registry/findings.md#air-nn | closed | site/content/approaches | есть | — (21 случай, разгон 1,19 против 1,13 ✓) | tools/research/windninja/out/fig_ongudai_007.png, fig_t_0353_003.png | S | — |
| Маятник: каналы, срыв, Vmax «на себя», переворот | docs/registry/pendulum-findings.md; docs/research/pendulum.md | active | site/content/mechanics/flight | частично | ru свежий (VM-12/VM-6, 1.5.21). en: абзац «Tumble when coming out of the dive» не обновлён — «Not fixed yet», 40 из 48, до 51 g; в ru: 1,8·Vтрим 29 → 0, полный «на себя» 26 → 4, с добором 40 → 26 | tools/research/pendulum/out/fig/phugoid.png, reversal.png, ground_run.png, pendulum.png, full_shift.png; tools/research/pendulum/out/pb2/fig/vmax_vg.png | S | ок |
| Выход `sport` из штопора (1.5.21) | docs/research/pendulum/spin-recovery.md | active | site/content/mechanics/flight | есть | — (pull, затем центр; 2,2–7,2 с ✓ в ru и en) | нет | S | ок |
| Земля: предел бега, разбег, боковой ветер стоя, пустырь старта | docs/registry/findings.md#control-fix; docs/registry/findings.md#start-fixes | active | site/content/mechanics/flight | частично | Разбег 15–21 м, отрыв 2,8–3,4 с есть; нет порога бокового ветра стоя (sport, встречный 4 м/с — 1,90 м/с; при 6 м/с 0,6–1,0 м/с), пустыря ≥ 2× длины разбега, зазора крыла 0,58 м | tools/research/pendulum/out/fig/ground_run.png | S | ок* |
| Линейка крыльев: 48 моделей, паспорта, классы | docs/registry/findings.md#wings-lineup; docs/research/wings_config_sources.md | active | site/content/wings/_index | есть | — (3 + 11 + 19 + 15 = 48 совпадает с `configs/wings`) | нет (рендеры крыльев уже на страницах site/content/wings/*) | S | ок |
| Управление: мышь, геймпад, самодельная трапеция (HID) | docs/research/control-bar-input.md; docs/registry/findings.md#ui-controls | active | site/content/mechanics/flight | частично | Фраза про мышь, стик и «самодельную трапецию» есть; нет инструкции: стандартный USB HID с двумя осями (Arduino Leonardo/Pro Micro), Godot 4.5+ | нет | M | ок* |
| Ощущение скорости (SPF-1…5) | docs/research/speed-feel.md | active | site/content/mechanics/flight | нет | Нет вывода: болтанка растёт как V^1,2–1,5 (при 2·Vтрим в 2,0–3,1 раза), θ(V) −15°, число Струхаля ленты 0,4, тросы Ø 2–3,2 мм St 0,2, голова следует за 0,3 с | нет (tools/research/speed-feel/: скрипты и json, картинок нет) | M | ок* |
| Теория дельтапланеризма: Жеглов 1983, Ордоди 1984 | docs/research/zheglov-1983.md; docs/research/ordodi_1984_konstruktsiya.md | active | site/content/research/_index | частично | Ордоди есть в таблице research/_index (ru и en), Жеглова там нет — он назван только в flight (границы модели, литература) | нет | S | — |
| Источники рельефа и покрова | docs/research/terrain_sources.md | active | site/content/mechanics/terrain | есть | — (Copernicus GLO-30, DSM вместо DTM, WorldCover ✓) | build/screenshots/mountain-look/after_25_everest_behind.jpg | S | ок* |
| Данные места в WebP lossless | docs/research/location_compression.md; docs/registry/findings.md#no-osm | active | site/content/mechanics/terrain | есть | — (шаг 1/32 м ✓ с кодом). Реестр findings (no-osm) устарел: шаг 1/8, «55,3 → 24,2 МБ» — см. расхождения | нет | S | ок |
| Тайлы OSM: упаковка на Rust, шов регионов, планета | docs/registry/findings.md#osm-tiles | active | site/content/mechanics/terrain | частично | Структура тайла, пояса 0,18°, ≈ 20 км, ODbL есть. Нет (в основном служебное): Казахстан 6119 тайлов за 5,4 с против Python на порядок, оценка планеты 7,2–7,4 ГБ в R2 (прогон не выполнялся) | нет | S | ок |
| Сборка места по координатам, паритет с Python | docs/registry/findings.md#osm-any | active | site/content/mechanics/terrain | есть | — (пример на странице — Аушкуль 55,8 с, 166 запросов; числа реестра — другие места) | нет | S | ок* |
| Посёлки по застройке WorldCover, вода без OSM | docs/registry/findings.md#no-osm | active | site/content/mechanics/terrain | есть | — (8-связные пятна, маска воды max(WorldCover, реки) ✓) | build/screenshots/fast-load/FL-4/ongudai_mask_before.png, ongudai_mask_after.png | S | ок* |
| Растительность и дома по региону (T-83, RV-14) | docs/research/regional-vegetation.md; docs/research/house-models.md | active | site/content/mechanics/terrain | устарело | Страница: 5 пород (берёза, лиственница, кедр, ель, сосна). В игре с 1.5.19 8 моделей (+ дуб, пальма, тропическое), деревья и дома выбирает карта Кёппена–Гейгера (`configs/biomes.json`, 3 КБ, 85 % мира); сельские дома — модели, город — коробки | build/screenshots/regional-veg/models/oak/iso45.png, palm/iso45.png, tropical/iso45.png, houses/tin_house/side_lod0.jpg | M | ок* |
| Трава: средняя дистанция, angle против shell, цена (GR) | docs/perf/grass_rocks_2.md; docs/registry/findings.md#grass-rocks | active | site/content/mechanics/visual-cues | частично | Кольца 14/36/115 м и качание есть; нет выбора angle вместо shell (полосы ниже ~15°, просвет 0,35 м), ранний выход травы high 1,18 → 0,90 мс (−24 %), камни 16 800 → 1160 треугольников | build/screenshots/grass-rocks/01_start_cockpit.png, 04_low_meadow_chase.png; build/screenshots/grass-look/GR-21-1 | S | ок |
| Пресеты графики и их цена | docs/perf/frame_profile/after-fixes.md; docs/guide/scene-look/forest-cost.md | active | site/content/mechanics/terrain | частично | Таблица пресетов совпадает с `configs/game.json` (облака 90/160/220, деревья, тени). Нет: масштаб 3D 0,75 + FSR на «Низком», MSAA, SSAO off; цифры 4,14/5,59/5,74 мс — из scene-look, не PF-10 | нет | S | ок |
| Визуальные признаки для пилота (VR-1…VR-30) | docs/research/visual_cues.md | closed | site/content/mechanics/visual-cues | есть | — (птицы, пух, дым, рябь, ленточки перечислены) | build/screenshots/mountain-look/after_27_everest_morning.jpg | S | ок* |
| Вариометр 1990-х: тембр, звуки полёта | docs/research/vario_sounds.md; docs/research/sounds.md | active | site/content/mechanics/instruments | есть | — (меандр до 11-й гармоники, резонанс 3,2 кГц ✓) | нет | S | ок* |
| Боты и эталоны XC | docs/research/xc_reference.md | active | site/content/mechanics/bots | есть | — (бот без облаков садится за 5–6 км — оговорка в weather) | нет | S | ок* |
| Цели и правила соревнований | docs/research/competition_rules.md; docs/registry/findings.md#goals | active | site/content/docs/goals | есть | — (формула V = 16,7·c/(c + 1,9) в руководстве, на странице — словами «грубая формула»; GAP в игре нет) | build/screenshots/goals/GL-6/a4_result.jpg, b2_track_far.jpg | S | ок |
| Steam: GodotSteam, лицензии, политика тайлов | docs/research/steam_godotsteam.md; docs/research/steam_tile_policy.md; docs/research/steam_license_audit.md | active | site/content/mechanics/multiplayer | частично | Лобби «только друзья» до 16 и транспорт есть; нет: сборка Steam с GDExtension 4.22.1 (MIT), itch-сборка без аддона, Auto-Cloud на 4 файла, 100 файлов без строки ASSETS.md (служебное) | нет | S | ок* |
| Сеть без VPS: itch, Tailscale/ZeroTier | docs/research/itch_multiplayer.md | closed | site/content/mechanics/multiplayer | есть | — (отложено, «что рассматривали» есть) | нет | S | — |
| Платформа движения: SRS v102, SimHub | docs/research/motion-rig-protocols.md; docs/research/simhub.md | active | новая: mechanics/motion-rig | нет | Совсем нет: пакет SRS API v102 (236 байт, UDP 33001, 60 Гц), формат `generic`, девять флажков знака, «Настройки → Платформа подвижности». SimHub не читает SRS v102 — отдельный путь (оценка 1–2 дня, не сделан) | нет (бинарный протокол; диаграмма потока данных — схема, не график) | L | ок |
| Тренировочный остров: воздух | docs/research/training_island_air.md | active | новая: mechanics/training | нет | Нет страницы: склон 6 м/с — w +1,83 м/с (5 м/с +1,41, 8 м/с +2,52, подъём во всех 153 точках), термики 15 июля, 12 ч: ядро p50 1,98 / p90 2,66 / макс 4,1 м/с. См. и SRS-2 (функции) | build/screenshots/training-island/TI-1/00_top.jpg, 01_ridge_west.jpg, 02_thermal_plain.jpg, 04_lee_bowl.jpg; TI-5/ridge_west_f3.jpg | L | ок* |
| Статистика и настройка процедурного рельефа | docs/research/terrain_statistics.md; docs/research/terrain_tuning.md | closed | site/content/approaches | нет | В approaches процедурный рельеф упомянут только как набор обучения; нет вывода: сумма форм даёт 92–96 % дисперсии на 400 м, но в 3–7 раз меньше вершин; Fastscape воспроизводит перегибы; χ²/ndf 1,47 против 1,79 | tools/research/air_synth/terrain_stats/out/fig_compare.png, fig_curves.png | S | — |

## Расхождения docs с main

Записаны без правок (`docs/` не трогался).

- `docs/guide/atmosphere.md`: таблица файлов `scripts/atmosphere/` не содержит `cloud_field.gd`, `cloud_field_sources.gd`, `cloud_field_codec.gd` и `air_field_cache.gd`; в обзоре облака описаны как «на термик». Подробности есть в `docs/guide/atmosphere/clouds.md` (оно верно — совпало с `configs/atmosphere.json → cloud_field`). Правка текста; проверка игры не нужна.
- `docs/registry/findings.md#no-osm`: «шаг 1/8 м, ошибка ≤ 0,0625 м, 4 места 55,3 → 24,2 МБ». В коде `HEIGHT_STEP_M = 0.03125` (1/32 м), в `docs/research/location_compression.md` и `docs/guide/location-data.md` — 1/32 м, ошибка 0. Реестр устарел; сайт верен.
- `docs/registry/findings.md#air-model` («Лес»: d = 0,7·h_c = 12,6 м) против `configs/world.json → canopy_dsm_height_m` = 10 и `configs/atmosphere.json → h_c` = 0,77: это разные параметры или одно устарело — по чтению кода не определить (в `docs/guide/air-model/*.md` числа 12,6 нет). Нужно решение координатора/автора.
- Сайт, не docs: `site/content/mechanics/flight.en.md`, абзац «Tumble when coming out of the dive» отстаёт от `flight.ru.md` (VM-12, VM-6): «Not fixed yet», 40 из 48, 51 g против 29 → 0, 26 → 4, 40 → 26. Остальные ru/en-пары совпали по числу заголовков и чисел (`approaches`, `terrain`, `weather`, `thermals`, `multiplayer`).
- `docs/guide/net-protocol.md` и `site/content/mechanics/multiplayer`: guide описывает снимок поля облачности в `ZoneState` (10–25 КБ раз в 30 с), страница — нет (см. таблицу).

## Для шлюза координатора

Проверка поведения игры, а не текста: `site/content/mechanics/air-model/turbulence` утверждает «над лесом болтанка занижена — поверхность везде луг», а нагрев и шероховатость ветра в игре учитывают покров. Верно ли это для болтанки (игру не запускали) — проверить в игре. Строка таблицы: «Лес в модели воздуха».

## По страницам

Для каждой страницы: темы (по строкам таблицы), предлагаемые графики, суммарный объём. Графики — пути из таблицы; на странице сейчас картинок: clouds 4, air-model/_index 4, thermals 2, turbulence 1, flight 3, terrain 3, weather 1, wind-phases 0, approaches 0, research/_index 0.

### site/content/mechanics/clouds
Темы: поле облачности; цена слоя облаков. Примечание: пишет модуль site-cloud-field (SCF-1) — не трогать до его конца.
Графики: build/screenshots/cloud-field/CLF-1/ongudai_strong.png и ongudai_weak.png (сильный и слабый день); CLF-5/ongudai_high.jpg и ongudai_low.jpg (вид неба); CLF-5/cost.json (цена слоя, таблицей); CLF-9/almaty_strong_zi.png (потолки).
Объём: L.

### site/content/mechanics/air-model/thermals
Темы: z_i по рельефу; опускание (CLF-10); нагрев по покрову; источник термика не над водой.
Графики: build/screenshots/cloud-field/CLF-9/almaty_strong_zi.png; CLF-9/ongudai_strong_zi.png; CLF-10/almaty_strong_sub.png; tools/research/air_thermals/out/fig_before_after_ongudai_d400_h12.png.
Объём: M + M + S = L (две новые подсекции и одна подпись).

### site/content/mechanics/air-model/wind-phases
Темы: фазы ветра: границы, порог U/N, штиль.
Графики: tools/research/air_phase/out/fig_phase_schematic.png; fig_cases_game.png; fig_nonconv_fr_game.png; fig_order_game.png; fig_sections.png.
Объём: M.

### site/content/mechanics/air-model/turbulence
Темы: отрыв за грядой; AP-10; лес в модели воздуха.
Графики: tools/research/air_turb/out/spectrum.png; tools/research/air_phase/out/fig_shear_layer.png; tools/research/cases/perdigao/out/fig_section_ne.png; fig_section_sw.png.
Объём: S; лес — после ответа шлюза.

### site/content/mechanics/air-model/_index
Темы: калибровка Professor, Askervein + Perdigão.
Графики: tools/research/tune/out/fig_s1_chi2.png; tools/research/recal/out/fig_chi2_lf_alpha.png; tools/research/cases/b1/out/fig_fit_residuals.png.
Объём: S.

### site/content/approaches
Темы: Моррис и Pr_t; k_relax (А2); AS-1; WPC; кеш поля; нейросеть; WindNinja; статистика рельефа.
Графики: tools/research/morris/out/fig_degeneracy.png; tools/research/a2pre/out/fig_a2_hist.png; tools/research/air_start/out/after/fig/02_wind6_vs_trim.png; tools/research/wing_physics_check/out/fig_penetration_6ms.png; tools/research/windninja/out/fig_ongudai_007.png.
Объём: M (8 тем по S, страница в 51 КБ без картинок).

### site/content/research/_index
Темы: клеточный автомат; Жеглов/Ордоди (одна строка в таблицах ru и en).
Графики: tools/research/heat_ca/out/time_50.png; conv_flow.png; mass_balance.png.
Объём: S.

### site/content/mechanics/flight
Темы: Маятник (en-абзац); выход из штопора; земля и боковой ветер; управление (HID); ощущение скорости; Жеглов.
Графики: tools/research/pendulum/out/fig/phugoid.png; reversal.png; ground_run.png; tools/research/pendulum/out/pb2/fig/vmax_vg.png.
Объём: S + S + S + M + M = M.

### site/content/mechanics/terrain
Темы: источники рельефа; WebP; тайлы OSM (Rust); сборка по координатам; посёлки; растительность и дома по региону; озёра; пресеты графики.
Графики: build/screenshots/regional-veg/models/oak/iso45.png; palm/iso45.png; tropical/iso45.png; build/screenshots/regional-veg/models/houses/tin_house/side_lod0.jpg; build/screenshots/fast-load/FL-4/ongudai_mask_after.png.
Объём: M (растительность и дома) + 4 × S = M.

### site/content/mechanics/visual-cues
Темы: трава (angle/shell, цена); визуальные признаки; дымка (после haze-humidity).
Графики: build/screenshots/grass-rocks/01_start_cockpit.png; 04_low_meadow_chase.png; build/screenshots/grass-look/GR-21-1; build/screenshots/mountain-look/after_27_everest_morning.jpg.
Объём: S.

### site/content/mechanics/weather
Темы: погода из прогноза; точка росы (после haze-humidity).
Графики: нет готовых.
Объём: S.

### site/content/mechanics/multiplayer
Темы: облачное поле по сети; Steam; itch.
Графики: нет готовых.
Объём: S.

### site/content/mechanics/instruments, bots, docs/goals, wings/_index
Темы: вариометр; боты; цели; линейка крыльев — вывод на странице есть.
Графики (по желанию): build/screenshots/goals/GL-6/a4_result.jpg; b2_track_far.jpg; build/screenshots/training-modes/goals.png.
Объём: S каждая.

### новая: mechanics/motion-rig
Темы: платформа движения (SRS v102, SimHub).
Графики: нет готовых — нужна схема потока данных (рисовать).
Объём: L.

### новая: mechanics/training
Темы: тренировочный остров (воздух); пересечение с SRS-2 (тренировки).
Графики: build/screenshots/training-island/TI-1/00_top.jpg; 01_ridge_west.jpg; 02_thermal_plain.jpg; 04_lee_bowl.jpg; build/screenshots/training-modes/window.png.
Объём: L.

## Воспроизведение

Данных и скриптов нет — аудит чтением. Команды, которыми собирались сведения:

```
cd ~/deltaplan-site-research-SRS-1
.dpcli/dpcli task show SRS-1
cut -c1-230 docs/registry/research.md ; cut -c1-260 docs/registry/findings.md
find site/content -name '*.ru.md' -not -path '*/releases/*' | sort
# пары ru/en: число заголовков и чисел
grep -oE '[0-9]+([,.][0-9]+)?' <страница>.ru.md | wc -l ; то же для .en.md
# сверка с кодом: configs/atmosphere.json, configs/weather_model.json, configs/game.json, scripts/terrain/build/dem_stage.gd, scripts/motion_rig/motion_output.gd
```

Источники — файлы репозитория (ссылки в колонке «Источник»); внешних данных и лицензий нет.
