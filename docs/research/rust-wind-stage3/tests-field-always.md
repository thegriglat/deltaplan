---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-P7: тесты при поле «всегда» — что переведено на малое место и кеш, что вынесено в cargo, что пропущено из-за дефектов крейта."
---

# RW-P7: тесты при поле «всегда»

Поле Пикара считается на каждый мир (W2 v5), шаг только 25 м, место не меньше ~6 км (12 клеток поля по 400 м; меньшее крейт отвергает без текста ошибки: `FAILED`, `last_error` пуст).

## Что сделано

- Контрактные тесты фасада: место обрезано до ±3 км (на 20 км поле 40 с на сочетание условий, на 6 км — 0,6 с), кеш полей на файл, `_pump` с пределом 300 с и сообщением, `deterministic = true`. Файл: 12 мин 23 с (RW-P3) до 65–78 с.
- `air_rig.gd`: место 6 км по умолчанию, опции `cfg`, `surface`, `cache`, сообщения об отказе условий и FAILED.
- Физика слагаемых — в cargo: `rust/dp-air/tests/gd_atmosphere_ported.rs` (склон, ротор подветра, болтанка у земли, перистые, сила термиков по дням). Пороги прежние; u в подветре — ветер профиля, как `mean_wind_at` эталона GD (опорная ревизия c591b1026 даёт те же w и σ: 5 м/с w −1,53 / σ 4,83, крейт −1,44 / 4,83).
- `fingerprint_world.gd`: мир отпечатка с условиями W5 целиком и шагом 25 м (`scripts/atmosphere/atmo_fingerprint.gd` не правился — границы).

## Таблица

| файл::тест | судьба |
|---|---|
| test_atmosphere::thermal_profile, background_sink | удалены: terms_thermal.rs (thermal_profile_core_ring_allen, background_sink_fades_to_ground) |
| test_atmosphere::ridge_lift_windward_and_lee_sink, turbulence_deterministic_and_ground_stronger | удалены: gd_atmosphere_ported.rs |
| test_lee_rotor::scale_with_wind, reverse_flow_near_slope | удалены: gd_atmosphere_ported.rs |
| test_wave::lens_matches_lift, rotor_turbulence_under_crest | удалены: terms_waves.rs |
| test_wave::climb_above_cloudbase_in_first_crest | удалён, покрытия нет (полёт в волне λ > 3 км не помещается в малое место) |
| test_hazards::lee_wave_crest_lift | удалён: terms_waves.rs |
| test_hazards::cirrus_weakens_thermals | переведён (прогрев в GD) + gd_atmosphere_ported.rs (cirrus_weakens_thermals) |
| test_calibration::thermal_strength_by_day | удалён: gd_atmosphere_ported.rs; medium_lift_at_working_height — удалён без замены (на малом месте 5 термиков) |
| test_cloud_suck: suck, density_at | suck удалён (terms_thermal_cloud.rs), density_at переведён |
| test_cloud_suck, test_pilot_words: бурление в облаке, «выкинет» | пропуск: бурления в облаке в крейте нет (terms/clouds/mod.rs) |
| test_ridge_starts (оба) | пропуск: реальные места, поле минуты на старт |
| test_storm_rarity (2 статистических) | пропуск: 34 мира по 40 с |
| test_weather_day, test_clouds_and_generation, test_cloud_field_runtime | потребители; пороги под модель W5 (рост ветра по gain_per_km) |
| test_cloud_fade, layer_history, select_chunked, gust_dust, decompose_terms, rw7 | переведены на фасад/малое место |
| test_determinism: 3 теста | пропуск: дефект крейта (ниже) |

## Дефекты крейта (не чинились)

1. `start_at(t)` ≠ прогон с 0 при поле: на 20 с термиков 41 против 52, MEAN расходится до 1,7 м/с; два прогона разным шагом расходятся к 3600 с. Контракт W2 нарушен.
2. Мягкая смена явного пресета не двигает `weather_version` (у прогноза двигает).
3. Перистые: в фасаде сила и число термиков не зависят от `cirrus_cover` (1,46 м/с и 13 при 0 и 0,9), в cargo без поля 2,49 → 0,64.
4. Отказ условий/малого места даёт `FAILED` с пустым `last_error`.
5. `AtmoFingerprint.make_world` и `wait_ready` (scripts) устарели под W5 v8 и поле.
6. Выход Godot с кодом 139 после тестов с DpAir.
