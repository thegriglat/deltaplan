extends TestCase
## Волна (VR-27) через фасад W2 v4: физика подъёма (sample) и лентикуляры (wave_crests) — одно и то
## же поле, стоят в одном месте. Проверка на синтетическом гребне; Онгудай и длина волны 2πU/N —
## в крейте (rust/dp-air/tests/terms_waves.rs: ongudai_lens_matches_lift, wave_term_matches_*).
## См. docs/archive/plan/atmosphere/06-volna-proverka.md.

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const RIDGE_H := 800.0
const RIDGE_W := 1500.0
const CREST_AT := Vector2(8000.0, 0.0)


static func _ridge(x: float, _z: float) -> float:
	return 500.0 + RIDGE_H * exp(-(x / RIDGE_W) * (x / RIDGE_W))


func _rig(over: Dictionary = {}, preset: String = "weather/wave", advance: float = 0.01) -> Atmosphere:
	return Rig.make(
		{
			"preset": preset,
			"over": over,
			"mode": 1,
			"ground": _ridge,
			"half": 3000.0,  # малое место (шаг 25 м, W5); большие места — в cargo
			"advance": advance,
		}
	)


# Физика волны на хребте ±20 км (test_synthetic_ridge_lens_matches_lift, test_rotor_turbulence_under_crest,
# test_climb_above_cloudbase_in_first_crest) — rust/dp-air/tests/terms_waves.rs
# (synthetic_ridge_lens_matches_lift, rotor_under_crest_and_no_wave_without_preset, crests_match_desc,
# ongudai_lens_matches_lift): при поле «всегда» шаг 25 м (W5) на таком месте для Godot — минуты.
# Здесь остаётся потребитель фасада на малом месте: волна включена пресетом и выключена без него.


func test_wave_enabled_by_preset() -> void:
	var a := _rig()
	check(a.wave_info()[Atmosphere.WAVE_INFO_ENABLED] > 0.5, "волна включена пресетом")
	check(a.wave_info()[Atmosphere.WAVE_INFO_LENGTH] > 0.0, "длина волны задана")
	a.free()


func test_no_wave_without_preset() -> void:
	var a := _rig({}, "weather/medium")
	check(a.wave_info()[Atmosphere.WAVE_INFO_ENABLED] < 0.5, "в обычный день волн нет")
	check(a.wave_crests(CREST_AT, 15000.0, 40.0).is_empty(), "без волны — нет линз")
	a.free()


# test_ongudai_lens_matches_lift (линза на рельефе Онгудая) — rust/dp-air/tests/terms_waves.rs
# (ongudai_lens_matches_lift, wave_term_matches_ongudai_terrain_reference, ongudai_wave_on_place_raster).
