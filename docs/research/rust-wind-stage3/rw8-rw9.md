---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-8a: разбор RW-8 (болтанка поля, шум порывов) и RW-9 (аналитика, полоса края, off): входы, выходы, крейт, тесты."
conclusion: "RW-8 — ~600 строк GD + порт шума; RW-9 — ~680 строк GD; общий швов: шум WindModel.gust_unit, wind.dir/profile и сумма σ в полосе края"
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3-path.md", "docs/research/rust-wind-stage3/godot-compat.md", "docs/research/rust-wind-stage3/fixtures.md"]
---

# RW-8 и RW-9: подробно (RW-8a)

Строки — `scripts/atmosphere/…` ветки `feature/rust-wind` на 2026-10-29; «Rust» — `rust/dp-air/src/…`. Объём Rust — оценка по чтению (×1,2–1,4 к GD, без тестов), не замер.

## RW-8. Болтанка поля и шум порывов

**Исходники.**
- `field_turbulence.gd` (271 строка): `setup` 59, `sep_sigma` 85 (σ слоя смешения 0,18·ΔU и 0,14·ΔU), `burst_mean/std` 91/98 + `_measure_burst` 257 (статистика рывков: сид 4242, 2048 случайных точек, ходит в `WindModel.gust_unit`), `reverse_unresolved` 107, `lee` 118 (признак отрыва по дефициту скорости против лог-профиля и опусканию столба), **`sigma` 138** (механика: u* стенки × (1 − z/h)^¾, длина перемешивания Прандтля λ = max(λ₀, λ/h·h); приземный слой — u* из ветра в точке; устойчивость Ri; конвекция Ленчова по w* поля; σ³-сложение; анизотропия MIL-HDBK-1797 и σ_v; масштабы L_u, L_w с поправкой σ_w/N), `taylor_stretch` 231, `mil_lw/lu` 242/249.
- `gust_spectrum.gd` (172): спектр фон Кармана по октавам (8 октав s = 8·2^i м, `_build_tables` 69 — 64 × 8 весов по L, `_band` 86), `sample` 109 (до 24 вызовов шума), `_weights` 141.
- `wind_model.gd` (шумовая часть, ~75 из 202): `setup` 51–104 (FBM 2 октавы, масштабы 45 и 300 м, сдвиги, `_measure_rms` 93), `gust_unit` 186, `_noise3` 197 — общая с RW-9 (аналитика) и с рывками RW-8.
- `atmosphere.gd`: турбулентная часть `_air_velocity_field` 1136–1213 (78 строк: `sigma` → `s_u,s_v,s_w` → рывки `w_burst` → ограничители `cap_h` → `l_sep` → `taylor_stretch` → `gusts.sample` → разворот вдоль/поперёк `e` → `tv`), `_lee_burst_g` 1224.

**Входы.**
- Конфиг: `turbulence.{field_sigma_w_per_ustar 1,25; field_mixing_length_m 40; field_conv_sigma_u_per_wstar 0,6; field_cbl_scale_per_zi 0,22; evolve_ms 0,6; advection_height_m 300; vertical_ratio 0,7; max_amplitude_ms 4,0; scale_m 45; large_scale_m 300; large_fade_agl_m 300; octaves 2}`, `lee.field_*` (14 ключей, в т. ч. `field_resolved_cells [4,8]`, `field_burst_per_du 0,42`, `field_reverse_per_uh 0,22`), `lee.{burst_threshold 0,8; burst_width 1,0; burst_scale_m 120; rotor_max_amplitude_ms 7,0}`; константы решателя `LAM_FRAC 0,0158`, `NEUTRAL_BL_K 0,3`, `F_COR 1,13e-4`, `KAPPA 0,4` (Rust: `field/case_prepare.rs:43`, `field/wind_profile.rs:39–42`).
- Из поля: 8 каналов `turb_at` (`T_SHEAR, T_N2, T_USTAR, T_UOUT, T_AOUT, T_DESC, T_WSTAR, T_HMIX`), `sample_dx`, скорость поля `fw`, доля `a`, `z0` уровня, ветер на уровне гребня `U_H` (второй опрос поля на высоте `h + relief`, `atmosphere.gd:1100`).
- Из других слагаемых: направление ветра `wd`, перенос `_advect = speed_at(300 м)` (профиль: RW-9/RW-12), `relief` (`GroundField.relief_at`: RW-9), `danger` (`_lee_danger`: RW-9), σ края термика `th.z` и маска (RW-10), `_storm_turb`, `_rotor_turb`, `_cin.x` (RW-11), конвективная σ аналитики `_conv_amp` (погода: RW-12), `time_s`, сид.
- Порядок в сумме: болтанка считается **после** `_extra_flow` — средний ветер в точке `mh` включает грозу, волну и выброс из облака (`atmosphere.gd:1141,1178`), поэтому вычисляется последней.

**Выходы.** Слагаемые W7 `turb` (поле: `tv`, σ_u) и часть `gust` (шум аналитики в полосе края `a < 1` и бурление в облаке); `total.w` = σ; дальше σ идёт в `turbulence_intensity_at`. Описаний (W6) нет.

**Состояние во времени.** Нет: шум «заморожен» и переносится ветром — чистая функция `(pos, t)`; таблицы фон Кармана и статистика рывков считаются один раз на сид.

**Случайность.** `FastNoiseLite` ×2 вида (`GustSpectrum`: симплекс-гладкий без фрактала; `WindModel`: симплекс-гладкий FBM), `RandomNumberGenerator` для сдвигов и нормировки. Решение и шлюз — `godot-compat.md`: **порт побитно**, замена — запасной путь.

**Что есть в крейте.** Все каналы и опрос поля: `Field::turb_at` (`wind_field.rs:750`), `FieldSet::sample_turb` (`field_set.rs:237`, усреднение по уровням и подмене с долей), `sample_dx` (`:269`); константы профиля. Нет: `FieldTurbulence`, `GustSpectrum`, шума, `wind.gust_unit`, суммы σ.

**Фикстуры.** Только `ongudai_*` (6 случаев, ≈ 1 300 точек-моментов `turb`, `fixtures.md`): σ итога, `sigma[turb]`, MEAN (σ в нём полная). точки с тегом `lee` — 4 в случае. Значения шума — T3 или побитно (порт). `synth_*` для RW-8 не годятся (поля нет).

**Тесты GDScript → cargo.** Прямых тестов `FieldTurbulence`/`GustSpectrum` в `tests/atmosphere/` нет — их заменяют: `test_lee_rotor.gd` (блок 2 «с полем воздуха», `test_field_*`: w в зоне отрыва, рывки ≤ 0,42·ΔU, σ_w ≈ 0,14·ΔU, обратный поток 0,22·U_H только на грубой сетке), `test_atmosphere.gd` (турбулентность, детерминизм шума), `test_determinism.gd` (отпечаток). Новые: T3 по плану (дисперсия, спектр, масштабы MIL-HDBK-1797, σ_u ≠ σ_v по длинной выборке), побитность порта по дампу, `taylor_stretch`, монотонность `sigma` по высоте.

**Объём.** ≈ 600 строк GD → ≈ 700–800 строк Rust + порт шума ≈ 300–350 (с таблицей градиентов) → 3–4 дня исполнителя (оценка).

**Риски.** (1) Форма `FastNoiseLite` Godot (поворот 3D, нормировка FBM) — не проверено, см. шлюз. (2) Порядок вызовов RNG при `setup` — сдвиги раньше нормировки, перестановка меняет шум. (3) σ_w зависит от `th.z`/`storm`/`rotor` — до RW-10/11 они нули, итог σ в `ongudai_*` не сойдётся там, где есть термики (края ядер, `thermal` 94–98 % точек): сверять `sigma[turb]` по формуле поля, итоговую σ — после RW-10/11. (4) Горячий путь: до 24 вызовов шума на точку — бюджет W8 (18 точек ≤ 50 мкс) оценён по 40–50 нс на вызов, ≈ 1 мкс на точку, запас ≈ 2×; замера нет. (5) `sample_many(MEAN)` в GD считает точку дважды (`atmosphere.gd:2064`), в крейте — один проход с флагом.

## RW-9. Аналитика и полоса края a < 1, режим `air_model.enabled = off`

**Исходники.**
- `wind_model.gd` (профильная часть ~125 строк): `set_wind` 106, `_update_profile` 132, `profile` 148, `speed_at` 152, `altitude_factor` 164, `speed_at_pos` 171, `vec2_at` 176; простой профиль `wind_profile_simple` (α 0,14, предел 1,8).
- `ground_field.gd` (251): сетка узлов 30 м кусками 16 × 16 (кеш ≤ 400 кусков), узел = (высота, dh/dx, dh/dz, линия тени, превышение гребня); линия тени — максимум по 6 дистанциям (60…1600 м) против ветра `h(p − ŵ·d) − d·tg 12°`; `sample` 107, `relief_at` 134, `is_water` 96, `mean_height` 238, `set_wind_dir` 73 (чистит кеш; зовётся из `Atmosphere.set_wind` только при повороте > 5°, `atmosphere.gd:782–784`).
- `atmosphere.gd`: `air_velocity_at` 921–988 (ветка без поля), `_ridge_lift` 990, `_analytic_amp` 1031, `_analytic_turb` 1047, `_lee_danger` 1215, `_lee_burst_g` 1224, `_lee_heat_factor` 1232, `_lee_flow` 1254, полоса края в `_air_velocity_field` 1075–1131 и смесь σ 1186–1213, `mean_wind_at` 1321, `background_wind` 2098, `_update_wind_conditions` 1303, режим `_update_air_mode` 700.

**Входы.** Конфиг `wind.*` (опорная высота 10 м, `shear_exponent_neutral 0,24`, `z_sat_frac`, `altitude_gain_per_km`, `altitude_min/max_factor`), `ridge.*` (эффективность 0,85, затухание 250 м, сдвиг 0,8·agl ≤ 400 м, предел 6 м/с), `lee.*` (углы и масштабы: `shear_layer_m 350`, `depth_scale_m 40`, `relief_scale_m 60`, `sink_per_wind 0,08/0,08`, `turbulence_per_wind 0,5/0,9`, `danger_min/full 2/5`, `burst_per_wind 1,0`, `rotor_reverse 0,65`, `rotor_height_fraction 0,6`, `heat_kill_wm2 300`, `wind_reduction 0,6`), `turbulence.{mech_per_wind 0,14; mech_ground_boost; mech_ground_height_m 150; vertical_ratio; max_amplitude_ms 4}`, `ground.{cell_m 30; chunk_cells 16; wind_dir_tolerance_deg 5; reference_radius_m 10000; reference_samples 15}`. Из места (W5): растр высот, вода/классы (`is_water`), старт `start_sites[0].h_msl` (опорная высота ветра `ref_msl`). Из погоды: `wind_speed_kmh`, `wind_from_deg`, `convective_turbulence_ms`, `background_sink_ms`, `_derived.sun_elev_deg`, `sky` (класс устойчивости профиля — `WindProfile` с часом и облачностью), `cloudbase_agl_m`, прогноз `wind_ref{ref_msl, gain_per_km}`.

**Выходы.** Слагаемые `analytic`, `ridge`, `gust` (W7); в полосе края — доля `(1 − a)` каждого; вертикаль `thermal` не здесь. Методы фасада: `background_wind` (профиль без рельефа), `weather()`-связь через условия профиля. Описаний нет.

**Состояние.** Кеш кусков `GroundField` (зависит от направления ветра; чистится при повороте > 5° — это состояние, надо сохранить: линия тени «отстаёт» от ветра до 5°, фикстуры снимали с этим поведением); условия профиля меняются по часу (`wind.set_conditions` на каждый шаг погоды: α и предел профиля уходят вслед за высотой солнца и облачностью — зависимость от RW-12).

**Случайность.** Шум порывов (`gust_unit`, RW-8). Своего RNG нет.

**Что есть в крейте.** Профиль: `wind_profile.rs` (`stability_class :84`, `alpha :92`, `max_profile :118`, `z_sat`), доля поля и край уровней: `FieldSet::sample` (`field_set.rs:169`, `edge_weight` smoothstep на 5 клетках, `wind_field.rs:534`), высота рельефа: `ground_height` (`runtime.rs:499`, билинейно по 25 м) и `ground_height_grid` (`:1609`, узлы 30 м — повторяет сетку `GroundField` для опроса). Нет: `GroundField` (склон, линия тени, превышение гребня), `ridge/lee`, режим `off`, подмешивание аналитики, `background_wind` (сейчас нули, `formula.rs:1186`), `mean_wind_at`-аналог, условия профиля по часу.

**Фикстуры.** `synth_*` (5 случаев, аналитика целиком: 117–189 точек-моментов на случай), `ongudai_*` (полоса края: `analytic` 30–96 точек-моментов, `ridge` 21–44), точки `lee` (4 в случае на Онгудае; на синтетике — рельеф без гребня) и `field_edge` (16 в дневном случае, 8 в пресете). Режим `off` — **не покрыт** (см. `fixtures.md`, п. 8): нужен случай RW-2c.

**Тесты GDScript → cargo.** `test_atmosphere.gd` (склон/подветренная сторона/кромка/профиль, 18 функций), `test_lee_rotor.gd` (первый блок: аналитика без поля, опускание, ротор, рывки; пороги эвристики), `test_wind_profile_simple.gd` (режим `off`), `test_ridge_starts.gd` и `test_calibration.gd` (боты — это T9, не cargo), `test_weather_day.gd` (ветер прогноза на старте и рост с высотой), `test_wind_field.gd` (поле — перенесено с RW-6i).

**Объём.** ≈ 680 строк GD → ≈ 800–900 Rust (профильный `WindModel` ≈ 130, `GroundField` как растр ≈ 250, сумма ≈ 450) → 2–3 дня (оценка).

**Риски.** (1) `GroundField` читает `terrain.height_at` (слои 25/10/… м), крейт — билинейно по растру 25 м: у склонов разница высот попадает в линию тени и градиенты (допуск W8 «растр вместо `height_at`» — отметка в отчёте с числом). (2) Кеш по кускам в GD ленив и зависит от порядка опросов (первый опрос после поворота ветра строит кусок по текущему `_wind_dir`); в крейте — растр на направление, публикуемый целиком: поведение совпадёт лишь при условии «пересчёт при повороте > 5°» и обнулении кеша при смене места. (3) Неопределённость сложения σ в полосе края: `k = 1/√(a² + (1−a)²)` и `σ² = a·s_u² + (1−a)·amp²` (`atmosphere.gd:1197–1202`) — формулы, не физика; переносить буквально. (4) Профильный `WindModel` задействован в RW-8 (`_advect`, рывки) и RW-10 (`vec2_at` сноса термиков) — интерфейс «ветровая рамка» нужно зафиксировать в каркасе (`cards.md`, RW-8b) до параллельной работы.
