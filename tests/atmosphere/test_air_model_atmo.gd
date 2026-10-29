extends TestCase
## Поле воздуха в атмосфере (AM-05, docs/guide/air-model.md → «Поле на CPU»): с полем прикидки Онгудая
## (окно 100 м у Каянчи, фикстура tools/research/air3d/to_game_field.py) air_velocity_at и
## mean_wind_at на старте дают горизонталь и механическую вертикаль поля; выключенное поле и точки
## вне поля — побитно аналитика; отпечаток детерминизма — всегда без поля; конфиг с _doc.

# test_kayancha_probes (air_velocity_at / mean_wind_at на старте = горизонталь и механическая
# вертикаль
# поля), test_off_and_outside_bitwise_analytic (выключенное поле и точки вне поля — побитно
# аналитика),
# test_edge_smooth_in_atmosphere (сглаженный край поля) — поле и аналитика в игре считает крейт
# (RW-12s:
# проверки через AirFieldSet в GD-атмосфере удалены): rust/dp-air/tests/terms_turb.rs
# (ongudai_replay_matches_air_velocity_field, slot_in_sum_on_island_field), terms_thermal_field.rs
# (field_region_covers_and_off), terms_analytic.rs (strip_has_no_jump_at_field_edge_t2,
# off_mode_case_equals_medium_and_uses_simple_profile), wind_field.rs.


func test_fingerprint_world_without_field() -> void:
	var w := AtmoFingerprint.make_world()
	check(String(w.cfg_override.air_model.enabled) == "off", "отпечаток: air_model.enabled = off")
	check(not w.is_air_field_on(), "отпечаток: поле не используется")
	w.free()
	check(
		String(Config.get_config("atmosphere").air_model.enabled) == "auto",
		"конфиг игры не тронут make_world"
	)


func test_config_documented() -> void:
	var am: Dictionary = Config.get_config("atmosphere").air_model
	check(am.has("_doc"), "air_model._doc")
	for k: String in am:
		if not k.ends_with("_doc"):
			check(am.has(k + "_doc"), "air_model.%s_doc" % k)
	check(String(am.enabled) in ["auto", "on", "off"], "enabled — auto|on|off")
