extends TestCase
## Калибровка погоды (карточка 03, входные данные A07) через фасад W2 v4: сила термиков по дням,
## подъём на оси зрелого ядра, статичный термик над источником, зрелый термик в 3 км от старта.
## Воздух — tests/atmosphere/air_rig.gd; ядра — cores (W6: x, z — ось у земли, lean — наклон оси,
## stage 1–2 — зрелость, w — пиковый подъём с огибающей).
## Генератор клеток GD (_cell_params/_spawn), снос и наклон ядра ветром, предпочтение гребня как
## источника — слагаемое крейта (RW-12s: проверки через поле термиков GD удалены, эквиваленты —
## rust/dp-air/tests/terms_thermal.rs: lifecycle_envelope_cut_and_drift, wind_lean_shifts_axis,
## wind_change_turns_lean, source_strength_controls_frequency; terms_thermal_src.rs:
## edge_boost_near_class_boundary).

const Rig := preload("res://tests/atmosphere/air_rig.gd")
const CS := Atmosphere.CORE_STRIDE

## Полоса «гребня» в синтетическом рельефе: |x| < _RIDGE_HALF_M — сильный источник.
const _RIDGE_HALF_M := 60.0
const _SUN_RIDGE := 1.0
const _SUN_PLAIN := 0.5


## Гребень вдоль Z (x ≈ 0): скалы/опушка — сильный источник, равнина — средний.
static func _sun_ridge(x: float, _z: float) -> float:
	return _SUN_RIDGE if absf(x) < _RIDGE_HALF_M else _SUN_PLAIN


## Зрелые ядра (stage 1–2) вокруг (0, 0): массив [x, z, y_src, top, w, lean_x, lean_z].
func _mature(a: Atmosphere, radius: float) -> Array:
	var out: Array = []
	var c := a.cores(Vector3.ZERO, radius)
	for j in range(0, c.size() - CS + 1, CS):
		var st := c[j + Atmosphere.CORE_STAGE]
		if st >= 1.0 and st <= 2.0 and (int(c[j + Atmosphere.CORE_FLAGS]) & 1) == 0:
			out.append(
				[
					c[j + Atmosphere.CORE_X],
					c[j + Atmosphere.CORE_Z],
					c[j + Atmosphere.CORE_Y_SRC],
					c[j + Atmosphere.CORE_TOP],
					c[j + Atmosphere.CORE_W],
					c[j + Atmosphere.CORE_LEAN_X],
					c[j + Atmosphere.CORE_LEAN_Z],
				]
			)
	return out


func _mean_strength(preset: String) -> float:
	var a := Rig.make({"preset": preset, "seed": 20, "advance": 3600.0})
	var s := 0.0
	var m := _mature(a, 6000.0)
	for c: Array in m:
		s += c[4]
	a.free()
	return s / float(maxi(m.size(), 1))


# ---------------------------------------------------------------- 1. Сила термиков по дням


# test_thermal_strength_by_day (средняя сила ядра по дням, A07) — rust/dp-air/tests/gd_atmosphere_ported.rs
# (thermal_strength_by_day) на ровной земле без границ; ядра против дампа GD — terms_thermal.rs
# (synth_core_set_matches_gd_dump). test_medium_lift_at_working_height (медиана подъёма на оси на 0,5 слоя,
# >= 20 зрелых термиков) — там же не воспроизводится: источники термиков есть только над местом, а малое
# место 6 км (шаг 25 м, W5) даёт 5 зрелых ядер вместо 20+ (мерить на большом месте — минуты поля).


# ---------------------------------------------------------------- 2. Снос ветром целиком


func test_static_thermal_stays_over_source() -> void:
	var a := Rig.make(
		{
			"over": {"wind_speed_kmh": 15.0, "wind_from_deg": 270.0},
			"statics": [[0.0, 0.0, 3.0, 100.0]],
			"advance": 600.0,
		}
	)
	var c := a.cores(Vector3.ZERO, 1000.0)
	check(c.size() >= CS, "статичное ядро есть")
	if c.size() >= CS:
		approx(c[Atmosphere.CORE_X], 0.0, 1.0e-3, "статичный (MVP) стоит над источником (x)")
		approx(c[Atmosphere.CORE_Z], 0.0, 1.0e-3, "статичный (MVP) стоит над источником (z)")
		check(c[Atmosphere.CORE_LEAN_X] > 0.0, "статичный наклонён ветром")
	a.free()


# ---------------------------------------------------------------- 3. Источники у стартов


func test_thermal_within_3km_after_start() -> void:
	# С гребня-старта в любой момент дня (каждые 2 мин за 2 ч) в 3 км есть зрелый термик.
	for preset in ["weather/medium", "weather/strong"]:
		var a := Rig.make(
			{
				"preset": preset,
				"over": {"wind_speed_kmh": 15.0, "wind_from_deg": 270.0},
				"moist": _sun_ridge,
				"seed": 20,
				"advance": 1200.0,
			}
		)
		var ok := 0
		var total := 0
		var smin := float(Config.get_config(preset).thermal_strength_ms[0])
		for k in range(10, 60):
			Rig.run(a, 120.0 if k > 10 else 0.0, 30.0)
			total += 1
			for c: Array in _mature(a, 3000.0):
				if c[4] >= smin:
					ok += 1
					break
		check(
			ok >= int(0.9 * total),
			"%s: зрелый термик в 3 км от старта в >= 90%% моментов: %d/%d" % [preset, ok, total]
		)
		a.free()
