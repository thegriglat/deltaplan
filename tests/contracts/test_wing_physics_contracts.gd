extends TestCase
## Контрактные тесты модуля wing-physics-check (docs/contracts/wing-physics-check.md): форма
## данных на стыках К1–К6. Без GPU. Правка контракта (версия +1) — вместе с правкой этого файла.

const CONTRACTS := {"К1": 2, "К2": 1, "К3": 1, "К4": 2, "К5": 1, "К6": 1}
const DOC := "res://docs/wing-physics-check_contracts.md"
const OUT := "res://tools/research/wing_physics_check/out/"
const K4_HEADER := (
	"wing,group,mass_case,pilot_mass_kg,total_mass_kg,src_key,quantity,unit,model,config,"
	+ "passport,passport_src,diff_pct"
)
const K5_HEADER := (
	"location,start,mode,wind_set_ms,hour,offset_m,agl_m,msl_m,ground_msl_m,u_h_ms,u_along_ms,"
	+ "w_ms,u_profile_model_ms"
)
const K6_HEADER := (
	"key,series,location,start,mode,wing,pilot_mass_kg,wind_set_ms,pitch,agl0_m,duration_s,"
	+ "gs_into_wind_ms,airspeed_ms,vz_ms,wind_h_ms,wind_w_ms,agl_end_m,climb_m,note"
)
const WING_FIELDS := [
	"area_m2", "span_m", "wing_mass_kg", "pilot_mass_min_kg", "pilot_mass_max_kg",
	"pilot_mass_ref_kg", "trim_speed_kmh", "full_pull_speed_kmh", "full_push_speed_kmh"
]
const REF_FIELDS := [
	"stall_speed_kmh", "min_sink_ms", "min_sink_speed_kmh", "best_glide", "best_glide_speed_kmh"
]


func test_contract_versions_in_doc() -> void:
	var text := FileAccess.get_file_as_string(DOC)
	check(not text.is_empty(), "нет " + DOC)
	for k in CONTRACTS:
		check(
			_section_version(text, k) == CONTRACTS[k],
			"%s v%d в документе контрактов" % [k, CONTRACTS[k]]
		)


## К1: поля конфига крыла, единицы и инварианты.
func test_k1_wing_config_shape() -> void:
	var dir := DirAccess.open("res://configs/wings")
	var n := 0
	for f in dir.get_files():
		if not f.ends_with(".json"):
			continue
		n += 1
		var id := f.get_basename()
		var w: Dictionary = Config.get_config("wings/" + id)
		for k in WING_FIELDS:
			check(w.has(k) and float(w[k]) > 0.0, "%s: поле %s > 0" % [id, k])
		for k in REF_FIELDS:
			check(w.reference.has(k), "%s: reference.%s" % [id, k])
		var pts: Array = w.polar.points_kmh_ms
		check(pts.size() >= 3, "%s: в поляре ≥ 3 точек" % id)
		for i in range(1, pts.size()):
			check(float(pts[i][0]) > float(pts[i - 1][0]), "%s: скорости поляры растут" % id)
		var stall := float(pts[0][0])
		var trim := float(w.trim_speed_kmh)
		check(stall < trim, "%s: сваливание %.1f < трим %.1f" % [id, stall, trim])
		check(trim < float(w.full_pull_speed_kmh), "%s: трим < на себя" % id)
		check(float(w.full_push_speed_kmh) < trim, "%s: от себя < трим" % id)
		# v2: с нейтральной трапецией крыло на разбеге не сорвано — нейтраль ≤ α_срыва − 3°
		var mass_ref := float(w.pilot_mass_ref_kg) + float(w.wing_mass_kg)
		var rho_ref := float(Config.value("flight", "air_density.polar_ref_kgm3"))
		var cl_max := WingPolar.new(pts, mass_ref, rho_ref, float(w.area_m2)).cl_max
		var a_stall := rad_to_deg(cl_max / float(w.lift_slope_per_rad)) + float(w.zero_lift_alpha_deg)
		var a_neutral := float(w.launch.alpha_neutral_deg)
		check(
			a_neutral <= a_stall - 3.0 + 1.0e-6,
			"%s: нейтраль разбега %.1f° ≤ α_срыва %.1f° − 3°" % [id, a_neutral, a_stall]
		)
		check(
			float(w.pilot_mass_min_kg) <= float(w.pilot_mass_ref_kg)
			and float(w.pilot_mass_ref_kg) <= float(w.pilot_mass_max_kg),
			"%s: эталонная масса в диапазоне" % id
		)
	check(n > 0, "есть крылья")


## К2: воздух «с севера» дует на +Z; воздушная скорость = velocity − air.
func test_k2_frame_and_relative_air() -> void:
	var a := _atmo()
	a.set_ground(func(_x: float, _z: float) -> float: return 0.0, func(_x, _z): return 1.0)
	a.set_wind(21.6, 0.0)
	a.step(0.01)
	var v := a.air_velocity_at(Vector3(0, 10.0, 0))
	approx(v.x, 0.0, 1.0e-3, "ветер с севера: x = 0")
	check(v.z > 0.0, "ветер с севера дует на +Z: %.3f" % v.z)
	var m := FlightModel.new()
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	m.setup(Config.get_config("wings/sport"), pilot, {"air_density": {"altitude_dependent": false}})
	var air := Vector3(0, 0, 6.0)
	m.reset_in_air(Vector3(0, 3000, 0), 0.0, 0.0, air)
	m.step(1.0 / 120.0, ControlInput.new(), func(_p: Vector3) -> Vector3: return air, Callable())
	approx(m.telemetry.airspeed, m.trim_speed(), 0.05, "воздушная скорость = |velocity − air|")
	approx(-m.velocity.z, m.trim_speed() - 6.0, 0.3, "путевая на север = трим − встречный 6 м/с")


## К3: в аналитике скорость меню — U на reference_height_m над ровной землёй (без опорной высоты).
func test_k3_menu_wind_is_u10() -> void:
	var a := _atmo()
	a.set_ground(func(_x: float, _z: float) -> float: return 0.0, func(_x, _z): return 1.0)
	a.set_wind(21.6, 270.0)
	a.step(0.01)
	var h := float(Config.value("atmosphere", "wind.reference_height_m", 10.0))
	var v := a.air_velocity_at(Vector3(0, h, 0))
	approx(Vector2(v.x, v.z).length(), 6.0, 0.05, "U(10 м) = ветер меню")
	approx(a.wind.speed_at(h), 6.0, 1.0e-3, "WindModel.speed_at(10 м)")


## К4–К6: заголовки csv (проверяются, когда файл уже есть — до WPC-1..3 его нет).
func test_k4_k6_csv_headers() -> void:
	for pair in [["wings_audit.csv", K4_HEADER], ["wind_profile.csv", K5_HEADER],
			["penetration.csv", K6_HEADER]]:
		var path: String = OUT + pair[0]
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		check(f.get_line().strip_edges() == pair[1], "заголовок " + pair[0])


func _atmo() -> Atmosphere:
	var a := Atmosphere.new()
	var w: Dictionary = Config._deep_merge(
		Config.get_config("weather/medium"), {"thermal_mode": "static"}
	)
	var cfg: Dictionary = Config._deep_merge(
		Config.get_config("atmosphere"), {"air_model": {"enabled": "off"}}
	)
	a.configure(cfg, w)
	a.turbulence_enabled = false
	return a


## Версия раздела «## <k>. … (vN» документа контрактов; −1 — раздела нет.
static func _section_version(text: String, k: String) -> int:
	var at := text.find("## %s." % k)
	if at < 0:
		return -1
	var line := text.substr(at, text.find("\n", at) - at)
	var v := line.find("(v")
	return int(line.substr(v + 2).to_int()) if v >= 0 else -1
